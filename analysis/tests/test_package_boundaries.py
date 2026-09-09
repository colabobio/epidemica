# SPDX-License-Identifier: Apache-2.0
"""Package boundaries, mechanically.

ADR-0001 states the rules that keep modules independently adoptable, and until now nothing checked
any of them. A boundary that is documented but unenforced is one an agent or a contributor crosses
without noticing, which is exactly how `epidemica_survey` came to be shaped unlike every other
module while every test stayed green.

These are deliberately structural: they read `pubspec.yaml` and import statements rather than
building anything, so they run in the analysis suite and cost nothing.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
import yaml

from epidemica_analysis import contracts

ROOT = contracts.repo_root()
PACKAGES_DIR = ROOT / "packages"
APPS_DIR = ROOT / "apps"

#: The platform package. Everything is allowed to depend on it; it may depend on none of them.
CORE = "epidemica_core"

#: Interface a package implements to become the glue between a capability and the platform.
GLUE_MARKER = re.compile(r"\bimplements\s+EmbeddedModule\b")

INTERNAL_IMPORT = re.compile(r"""import\s+['"]package:(epidemica_[a-z0-9_]+)/src/""")


def _pubspecs(directory: Path) -> dict[str, Path]:
    """Package name to its directory, for every pubspec directly under `directory`."""
    found = {}
    for pubspec in sorted(directory.glob("*/pubspec.yaml")):
        name = yaml.safe_load(pubspec.read_text())["name"]
        found[name] = pubspec.parent
    return found


PACKAGES = _pubspecs(PACKAGES_DIR)
APPS = _pubspecs(APPS_DIR)
EVERYTHING = {**PACKAGES, **APPS}


def _dependencies(directory: Path) -> set[str]:
    """Epidemica packages this one declares a dependency on."""
    spec = yaml.safe_load((directory / "pubspec.yaml").read_text()) or {}
    declared = {**(spec.get("dependencies") or {}), **(spec.get("dev_dependencies") or {})}
    return {name for name in declared if name.startswith("epidemica_")}


def _implements_module(directory: Path) -> bool:
    return any(GLUE_MARKER.search(p.read_text()) for p in (directory / "lib").rglob("*.dart"))


GLUE = {name: path for name, path in PACKAGES.items() if _implements_module(path)}


def test_the_packages_are_discovered():
    assert PACKAGES, "no Dart packages found; this suite would pass vacuously"
    assert CORE in PACKAGES


def test_core_depends_on_no_epidemica_package():
    """The one rule every document agrees on, and the one everything else rests on.

    Core defines the module interface. A dependency in this direction would mean the platform knew
    about an implementation of it, and the module set would stop being a property of the binary.
    """
    assert _dependencies(PACKAGES[CORE]) == set()


@pytest.mark.parametrize("name", sorted(EVERYTHING), ids=str)
def test_dependencies_resolve_within_the_workspace(name: str):
    for dependency in _dependencies(EVERYTHING[name]):
        assert dependency in PACKAGES, f"{name} depends on unknown package {dependency}"


def test_the_dependency_graph_is_acyclic():
    graph = {name: _dependencies(path) for name, path in EVERYTHING.items()}
    state: dict[str, int] = {}

    def visit(node: str, trail: list[str]) -> None:
        if state.get(node) == 2:
            return
        assert state.get(node) != 1, f"dependency cycle: {' -> '.join(trail + [node])}"
        state[node] = 1
        for nxt in sorted(graph.get(node, ())):
            visit(nxt, trail + [node])
        state[node] = 2

    for node in sorted(graph):
        visit(node, [])


@pytest.mark.parametrize("name", sorted(EVERYTHING), ids=str)
def test_nothing_reaches_into_another_package(name: str):
    """ADR-0001 rule 5: consumers use a package's public API, never its internals.

    A package's own tests may import its own `src/`; anything else is a dependency on a layout the
    owner is free to change, and would break for a consumer outside this repository.
    """
    offenders = []
    for source in EVERYTHING[name].rglob("*.dart"):
        if ".dart_tool" in source.parts or "build" in source.parts:
            continue
        for imported in INTERNAL_IMPORT.findall(source.read_text()):
            if imported != name:
                offenders.append(f"{source.relative_to(ROOT)} -> {imported}")
    assert not offenders, "\n".join(offenders)


def test_every_package_is_a_workspace_member():
    """A package missing from the list resolves from pub.dev instead, or not at all.

    The failure is confusing rather than loud: the package appears to exist and its own tests pass,
    while anything depending on it silently resolves something else.
    """
    workspace = set(yaml.safe_load((ROOT / "pubspec.yaml").read_text())["workspace"])
    for name, path in {**PACKAGES, **APPS}.items():
        relative = str(path.relative_to(ROOT))
        assert relative in workspace, f"{name} is not in the root pubspec workspace list"


class TestModulesStayIndependent:
    """ADR-0001 rule 2: dependencies point inward, never sideways between modules.

    A module may span several packages -- a federated plugin has a platform interface and
    per-platform implementations -- so the unit here is the set of packages reachable from a glue
    package, not the package.
    """

    @staticmethod
    def _module_packages(glue: str) -> set[str]:
        """Everything `glue` pulls in, excluding the platform itself."""
        seen: set[str] = set()
        queue = [glue]
        while queue:
            name = queue.pop()
            if name in seen or name == CORE or name not in PACKAGES:
                continue
            seen.add(name)
            queue.extend(_dependencies(PACKAGES[name]))
        return seen

    def test_at_least_one_module_is_found(self):
        assert GLUE, "no package implements EmbeddedModule; the rule below would be vacuous"

    def test_no_module_depends_on_a_sibling(self):
        owned = {glue: self._module_packages(glue) for glue in sorted(GLUE)}

        for glue, packages in owned.items():
            for other, other_packages in owned.items():
                if glue == other:
                    continue
                shared = packages & other_packages
                assert not shared, (
                    f"{glue} and {other} share {sorted(shared)}. Shared code belongs in a package "
                    "below both of them, or in a contract."
                )

    def test_only_glue_packages_know_the_platform_exists(self):
        """The shape the proximity stack established and `epidemica_survey` now follows.

        A capability is split in two: a package holding the domain logic, which knows nothing about
        outboxes or tokens and can be tested and adopted without them, and a thin package that
        implements `EmbeddedModule` and adapts one to the other. Only the second may name
        `epidemica_core`.

        ADR-0001 rule 2 permits a module to depend on core, and this narrows *where* in a module it
        may. Without it the domain logic and the adapter drift into one package, which is how a
        sensing library acquires a dependency on a storage library.
        """
        offenders = [
            name
            for name, path in PACKAGES.items()
            if name != CORE and CORE in _dependencies(path) and name not in GLUE
        ]
        assert not offenders, (
            f"{offenders} depend on {CORE} without implementing EmbeddedModule. Either the adapter "
            "belongs in a separate package, or this package is glue and should say so."
        )
