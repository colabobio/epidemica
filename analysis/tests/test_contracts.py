# SPDX-License-Identifier: Apache-2.0
"""Contract tests.

Fixture-driven and self-discovering: every schema in ``contracts/`` is found automatically, and its
fixtures are located by mirroring the schema path under ``contracts/fixtures/``. Adding a new
contract requires adding fixtures, not editing this file.

The negative fixtures matter more than the positive ones. A contract is defined by what it rejects,
and a rejection that fires for an incidental reason is not testing anything -- so each invalid case
is also checked to fail for exactly one reason.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator

from epidemica_analysis import contracts

SCHEMAS = list(contracts.iter_schema_paths())
ENVELOPE_ID = "https://schemas.epidemica.info/observations/envelope/1.0.0.json"
BATCH_ID = "https://schemas.epidemica.info/observations/batch/1.0.0.json"


def _rel(path: Path) -> str:
    return str(path.relative_to(contracts.contracts_dir()))


def _cases(kind: str):
    out = []
    for schema_path in SCHEMAS:
        for case in contracts.load_fixtures(schema_path, kind):
            out.append(pytest.param(schema_path, case, id=f"{_rel(schema_path)}::{case['case']}"))
    return out


# -- the schemas themselves ------------------------------------------------------------------


def test_at_least_one_schema_is_discovered():
    assert SCHEMAS, "no schemas found; the discovery rule or repo layout has changed"


@pytest.mark.parametrize("path", SCHEMAS, ids=_rel)
def test_schema_is_valid_json_schema(path):
    Draft202012Validator.check_schema(contracts.load_schema(path))


@pytest.mark.parametrize("path", SCHEMAS, ids=_rel)
def test_schema_id_matches_its_location(path):
    """$id must mirror the path, so a schema URI can be resolved offline from the repo alone."""
    expected = f"https://schemas.epidemica.info/{_rel(path)}"
    assert contracts.load_schema(path)["$id"] == expected


@pytest.mark.parametrize("path", SCHEMAS, ids=_rel)
def test_schema_is_documented(path):
    schema = contracts.load_schema(path)
    assert schema.get("title"), "every contract needs a title"
    assert len(schema.get("description", "")) > 40, "every contract needs a real description"


@pytest.mark.parametrize("path", SCHEMAS, ids=_rel)
def test_object_schemas_are_closed(path):
    """Contracts are closed so a module cannot quietly ship fields nobody agreed to store."""
    schema = contracts.load_schema(path)
    if schema.get("type") == "object":
        assert schema.get("additionalProperties") is False, f"{_rel(path)} must be closed"


@pytest.mark.parametrize("path", SCHEMAS, ids=_rel)
def test_payload_contracts_have_fixtures(path):
    valid = contracts.load_fixtures(path, "valid")
    invalid = contracts.load_fixtures(path, "invalid")
    if _rel(path).startswith("observations/batch/"):
        pytest.skip("batch is exercised by the dedicated tests below")
    assert valid, f"{_rel(path)} has no valid fixtures"
    assert invalid, f"{_rel(path)} has no invalid fixtures"


# -- fixtures --------------------------------------------------------------------------------


@pytest.mark.parametrize("schema_path,case", _cases("valid"))
def test_valid_fixtures_pass(schema_path, case):
    errs = contracts.errors(case["instance"], contracts.load_schema(schema_path)["$id"])
    assert not errs, "; ".join(errs)


@pytest.mark.parametrize("schema_path,case", _cases("invalid"))
def test_invalid_fixtures_are_rejected(schema_path, case):
    schema_id = contracts.load_schema(schema_path)["$id"]
    assert contracts.errors(case["instance"], schema_id), "should have been rejected"


@pytest.mark.parametrize("schema_path,case", _cases("invalid"))
def test_invalid_fixtures_fail_where_expected(schema_path, case):
    """Guards against a negative fixture that passes for an incidental reason.

    A case that trips unrelated rules is testing nothing in particular, and will keep passing after
    the rule it was written for is deleted. The check is on distinct failing *paths*: one conceptual
    violation often trips several keywords at once (a malformed URI fails both ``format`` and
    ``pattern``), so counting raw errors would be misleading. A fixture whose violation genuinely
    spans several fields declares them in ``expect_paths``.
    """
    schema_id = contracts.load_schema(schema_path)["$id"]
    paths = contracts.error_paths(case["instance"], schema_id)
    expected = case.get("expect_paths")
    if expected is not None:
        assert paths == set(expected), f"expected {sorted(expected)}, got {sorted(paths)}"
    else:
        assert len(paths) == 1, (
            f"expected one failing path, got {sorted(paths)}; "
            "declare 'expect_paths' if the violation really spans several fields"
        )


@pytest.mark.parametrize("schema_path,case", _cases("invalid"))
def test_invalid_fixtures_explain_themselves(schema_path, case):
    assert case.get("why"), "an invalid fixture must say what rule it pins down"


# -- envelope and batch behaviour -------------------------------------------------------------


def test_envelope_does_not_validate_the_payload():
    """The envelope stays agnostic to payload content so payload contracts version independently."""
    envelope = dict(contracts.load_fixtures(_envelope_path(), "valid")[0]["instance"])
    envelope["payload"] = {"total": "nonsense", "not_a_real_field": True}
    assert not contracts.errors(envelope, ENVELOPE_ID)


def test_payloads_in_envelope_fixtures_match_their_schema_uri():
    """End-to-end pairing: the envelope validates the wrapper, schema_uri validates the payload."""
    known = {contracts.load_schema(p)["$id"] for p in SCHEMAS}
    checked = 0
    for case in contracts.load_fixtures(_envelope_path(), "valid"):
        env = case["instance"]
        if env["schema_uri"] in known:
            errs = contracts.errors(env["payload"], env["schema_uri"])
            assert not errs, f"{case['case']}: " + "; ".join(errs)
            checked += 1
    assert checked, "no envelope fixture referenced a local payload schema"


def test_batch_accepts_a_list_of_envelopes():
    batch = {"observations": [c["instance"] for c in contracts.load_fixtures(_envelope_path(), "valid")]}
    assert not contracts.errors(batch, BATCH_ID)


def test_batch_rejects_an_invalid_member():
    """Schema validity and ingest policy are deliberately different things: the schema rejects a bad
    member, while the *server* quarantines it and still accepts the rest of the batch."""
    good = contracts.load_fixtures(_envelope_path(), "valid")[0]["instance"]
    bad = contracts.load_fixtures(_envelope_path(), "invalid")[0]["instance"]
    assert contracts.errors({"observations": [good, bad]}, BATCH_ID)


def test_batch_rejects_empty_and_bare_array():
    assert contracts.errors({"observations": []}, BATCH_ID)
    assert contracts.errors([], BATCH_ID)


def _envelope_path() -> Path:
    return next(p for p in SCHEMAS if contracts.load_schema(p)["$id"] == ENVELOPE_ID)
