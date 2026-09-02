# SPDX-License-Identifier: Apache-2.0
"""Loading and validating Epidemica contracts.

The schemas in ``contracts/`` are the source of truth for every Epidemica component. This module
resolves them from the local tree rather than over the network, so validation works offline, in CI,
and against an unreleased branch.
"""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Any, Iterator

from jsonschema import Draft202012Validator
from referencing import Registry, Resource

#: Marker used to locate the repository root from anywhere inside it.
_ROOT_MARKER = "contracts"

FIXTURE_DIRNAME = "fixtures"


@lru_cache(maxsize=1)
def repo_root() -> Path:
    for parent in Path(__file__).resolve().parents:
        if (parent / _ROOT_MARKER).is_dir() and (parent / "LICENSE").exists():
            return parent
    raise FileNotFoundError("could not locate the Epidemica repository root")


def contracts_dir() -> Path:
    return repo_root() / _ROOT_MARKER


def iter_schema_paths() -> Iterator[Path]:
    """Every schema file in the contracts tree, fixtures excluded."""
    fixtures = contracts_dir() / FIXTURE_DIRNAME
    for path in sorted(contracts_dir().rglob("*.json")):
        if fixtures in path.parents:
            continue
        if "$id" in json.loads(path.read_text()):
            yield path


@lru_cache(maxsize=None)
def load_schema(path: Path) -> dict[str, Any]:
    return json.loads(Path(path).read_text())


@lru_cache(maxsize=1)
def registry() -> Registry:
    """A registry of every local schema, keyed by ``$id``.

    Cross-schema ``$ref`` (the batch referencing the envelope, for instance) resolves against this
    rather than by fetching the URI, so nothing here depends on schemas.epidemica.info being
    reachable or even existing yet.
    """
    reg = Registry()
    for path in iter_schema_paths():
        schema = load_schema(path)
        reg = reg.with_resource(schema["$id"], Resource.from_contents(schema))
    return reg


def validator_for(path: Path) -> Draft202012Validator:
    return Draft202012Validator(
        load_schema(path),
        registry=registry(),
        format_checker=Draft202012Validator.FORMAT_CHECKER,
    )


@lru_cache(maxsize=None)
def _validator_by_id(schema_id: str) -> Draft202012Validator:
    for path in iter_schema_paths():
        if load_schema(path)["$id"] == schema_id:
            return validator_for(path)
    raise KeyError(f"no local schema with $id {schema_id!r}")


def validate(instance: Any, schema_id: str) -> None:
    """Validate against the schema with this ``$id``; raises ``jsonschema.ValidationError``."""
    _validator_by_id(schema_id).validate(instance)


def errors(instance: Any, schema_id: str) -> list[str]:
    """Human-readable validation errors, empty when the instance is valid."""
    validator = _validator_by_id(schema_id)
    return [
        f"{e.json_path}: {e.message}"
        for e in sorted(validator.iter_errors(instance), key=lambda e: e.json_path)
    ]


def error_paths(instance: Any, schema_id: str) -> set[str]:
    """The distinct JSON paths that failed validation.

    Paths rather than error counts, because one conceptual violation often trips several keywords at
    once -- a malformed URI fails both ``format`` and ``pattern`` -- and counting raw errors would
    make a correct fixture look as though it were testing more than one thing.
    """
    return {e.json_path for e in _validator_by_id(schema_id).iter_errors(instance)}


def fixture_dir_for(schema_path: Path) -> Path:
    """Fixtures mirror the schema tree: ``contracts/<dir>/<v>.json`` -> ``contracts/fixtures/<dir>/``.

    Keeping the layouts parallel means a new contract is picked up by the test harness the moment
    its fixtures are added, with no test to write and no registry to update.
    """
    return contracts_dir() / FIXTURE_DIRNAME / schema_path.parent.relative_to(contracts_dir())


def load_fixtures(schema_path: Path, kind: str) -> list[dict[str, Any]]:
    """Load ``valid.json`` or ``invalid.json`` for a schema; empty list if absent."""
    path = fixture_dir_for(schema_path) / f"{kind}.json"
    if not path.exists():
        return []
    cases = json.loads(path.read_text())
    for case in cases:
        if "case" not in case or "instance" not in case:
            raise ValueError(f"{path}: every fixture needs 'case' and 'instance' keys")
    return cases
