# SPDX-License-Identifier: Apache-2.0
"""Reference study bundles.

A study bundle is the only artefact a Tier 1 researcher authors, so it needs the same treatment as
any other contract: validated, and checked for the thing that would quietly undermine the tier.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from epidemica_analysis import contracts

STUDIES_DIR = contracts.repo_root() / "studies"
BUNDLE_SCHEMA = contracts.contracts_dir() / "bundle" / "1.0.0.json"
BUNDLES = sorted(STUDIES_DIR.glob("*/bundle.json"))

#: Anything here would mean a study shipped behaviour rather than configuration.
CODE_SUFFIXES = {".dart", ".kt", ".java", ".swift", ".m", ".mm", ".py", ".ex", ".exs", ".js", ".ts"}


def test_there_is_at_least_one_reference_study():
    assert BUNDLES, "studies/ should contain at least one reference bundle"


@pytest.mark.parametrize("path", BUNDLES, ids=lambda p: p.parent.name)
def test_bundle_validates(path: Path):
    instance = json.loads(path.read_text())
    errors = sorted(contracts.validator_for(BUNDLE_SCHEMA).iter_errors(instance), key=str)
    assert not errors, "\n".join(f"{e.json_path}: {e.message}" for e in errors)


@pytest.mark.parametrize("path", BUNDLES, ids=lambda p: p.parent.name)
def test_bundle_names_at_least_one_module(path: Path):
    """A study that activates nothing enrols successfully and produces an empty dataset."""
    assert json.loads(path.read_text())["modules"]


def test_studies_contain_no_code():
    """The Tier 1 claim, mechanically.

    If a reference study cannot be expressed without application code, then a study is not really a
    configuration document and ADR-0001's tier model does not hold.
    """
    offenders = [
        str(p.relative_to(contracts.repo_root()))
        for p in STUDIES_DIR.rglob("*")
        if p.is_file() and p.suffix in CODE_SUFFIXES
    ]
    assert not offenders, f"studies/ must contain no code, found: {offenders}"
