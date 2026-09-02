# SPDX-License-Identifier: Apache-2.0
"""Tests for the OpenAPI ingest specification.

Two things are checked: that the document is a valid OpenAPI 3.1 spec, and that the promises its
prose makes are actually encoded in it. The second matters more -- a spec that validates but quietly
drops the quarantine semantics would pass any off-the-shelf linter.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

from epidemica_analysis import contracts

SPEC_PATH = contracts.contracts_dir() / "api/ingest/v1.yaml"


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text())


def test_spec_exists():
    assert SPEC_PATH.exists()


def test_spec_is_valid_openapi(spec):
    from openapi_spec_validator import validate

    validate(spec)


def test_uses_openapi_31(spec):
    """3.1 aligns with JSON Schema 2020-12, which is what lets the spec $ref the contracts
    directly instead of maintaining a second, drifting copy of every shape."""
    assert spec["openapi"].startswith("3.1")


def test_batch_ref_resolves_to_the_real_contract(spec):
    ref = spec["paths"]["/observations"]["post"]["requestBody"]["content"]["application/json"]["schema"]["$ref"]
    target = (SPEC_PATH.parent / ref).resolve()
    assert target.exists(), f"{ref} does not resolve to a file"
    assert contracts.load_schema(target)["$id"].endswith("observations/batch/1.0.0.json")


def test_all_local_refs_resolve(spec):
    """Every $ref is either an internal component or a file that exists."""
    missing = []
    for ref in _iter_refs(spec):
        if ref.startswith("#/"):
            if _resolve_internal(spec, ref) is None:
                missing.append(ref)
        elif not ref.startswith(("http://", "https://")):
            if not (SPEC_PATH.parent / ref).resolve().exists():
                missing.append(ref)
    assert not missing, f"unresolvable refs: {missing}"


def test_contract_refs_are_relative_not_absolute(spec):
    """Relative refs resolve both as file paths and as URIs relative to $id, because every
    contract's $id mirrors its location. Absolute refs only work over the network."""
    absolute = [r for r in _iter_refs(spec) if r.startswith(("http://", "https://"))]
    assert not absolute, f"use relative refs to local contracts: {absolute}"


# -- the promises the prose makes -------------------------------------------------------------


def test_upload_returns_200_not_201(spec):
    """A batch is not simply 'created': some members may be quarantined or rejected, so the result
    body is the point and the status code must not imply blanket success."""
    responses = spec["paths"]["/observations"]["post"]["responses"]
    assert "200" in responses
    assert "201" not in responses


def test_ingest_result_reports_every_outcome_class(spec):
    result = spec["components"]["schemas"]["IngestResult"]
    for field in ("received", "accepted", "duplicate", "quarantined", "rejected"):
        assert field in result["properties"], f"IngestResult must report {field}"
        assert field in result["required"]


def test_quarantine_reasons_separate_recoverable_from_defect(spec):
    """The two cases share a status but need opposite responses: a version lag re-validates after a
    server upgrade, while a contract violation is a defect that will never fix itself."""
    reasons = set(spec["components"]["schemas"]["ObservationOutcome"]["properties"]["reason"]["enum"])
    assert {"unknown_envelope_version", "unknown_payload_schema"} <= reasons
    assert {"envelope_invalid", "payload_invalid"} <= reasons


def test_accepted_is_not_an_outcome_status(spec):
    """`exceptions` carries only what needs attention; listing every accepted item would make a
    clean 1000-item batch return 1000 redundant entries."""
    statuses = set(spec["components"]["schemas"]["ObservationOutcome"]["properties"]["status"]["enum"])
    assert "accepted" not in statuses
    assert statuses == {"duplicate", "quarantined", "rejected"}


def test_watermark_exposes_contiguous_sequence(spec):
    """Clients may only prune below the contiguous watermark; pruning below the maximum would
    discard observations sitting behind a gap."""
    props = spec["components"]["schemas"]["IngestWatermark"]["properties"]
    assert "highest_contiguous_seq" in props
    assert "highest_seq" in props


def test_watermark_takes_the_device_from_the_token(spec):
    """No path or query parameter for device_id, so one device cannot probe another's progress."""
    op = spec["paths"]["/observations/ack"]["get"]
    assert not op.get("parameters"), "watermark must not accept a caller-supplied device"


def test_every_response_carries_server_time(spec):
    """Clients without NTP use this as a fallback clock reference for the envelope."""
    for name in ("IngestResult", "IngestWatermark", "EnrollmentResponse", "TokenResponse", "Health"):
        schema = spec["components"]["schemas"][name]
        assert "server_time" in schema["required"], f"{name} must carry server_time"


def test_enrollment_and_token_endpoints_are_unauthenticated(spec):
    """They are how a client obtains a token, so requiring one would be circular."""
    for path in ("/enrollments", "/tokens"):
        assert spec["paths"][path]["post"]["security"] == []


def test_observations_endpoint_requires_auth(spec):
    """Inherits the global requirement rather than opting out."""
    assert spec["security"] == [{"participantToken": []}]
    assert "security" not in spec["paths"]["/observations"]["post"]


def test_subject_pattern_matches_the_envelope_contract(spec):
    """Enrollment and the envelope must agree on what a pseudonym is, or a client can enrol with a
    subject it can never use."""
    enrollment = spec["components"]["schemas"]["EnrollmentRequest"]["properties"]["subject"]
    envelope = contracts.load_schema(
        contracts.contracts_dir() / "observations/envelope/1.0.0.json"
    )["properties"]["subject"]
    assert enrollment["pattern"] == envelope["pattern"]
    assert enrollment["minLength"] == envelope["minLength"]
    assert enrollment["maxLength"] == envelope["maxLength"]


def test_errors_use_problem_details(spec):
    for name, response in spec["components"]["responses"].items():
        assert "application/problem+json" in response["content"], f"{name} should use RFC 9457"


def test_retryable_statuses_advertise_retry_after(spec):
    for name in ("TooManyRequests", "ServiceUnavailable"):
        assert "Retry-After" in spec["components"]["responses"][name]["headers"]


# -- helpers ----------------------------------------------------------------------------------


def _iter_refs(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "$ref" and isinstance(value, str):
                yield value
            else:
                yield from _iter_refs(value)
    elif isinstance(node, list):
        for item in node:
            yield from _iter_refs(item)


def _resolve_internal(spec, ref):
    node = spec
    for part in ref.lstrip("#/").split("/"):
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    return node
