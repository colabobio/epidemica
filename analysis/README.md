# epidemica-analysis

Contract validation, data-quality checks and FAIR tooling for Epidemica datasets.

Status: **early**. Currently this is the home of the contract test suite; the data-quality and
FAIR-scoring work described in the roadmap lands here as modules are built.

## Quick start

```bash
uv venv --python 3.13
uv pip install --python .venv/bin/python -e ".[dev]"
PYTHONPATH=src .venv/bin/python -m pytest tests -q
```

## Contracts

`epidemica_analysis.contracts` loads the schemas in `contracts/` from the local tree rather than
over the network, so validation works offline, in CI, and against an unreleased branch. Nothing
depends on `schemas.epidemica.info` being reachable — or existing.

```python
from epidemica_analysis import contracts

contracts.validate(payload, "https://schemas.epidemica.info/observations/location/location_fix/1.0.0.json")
problems = contracts.errors(payload, schema_id)   # list[str], empty when valid
```

## The test suite

Fixture-driven and self-discovering. Every schema under `contracts/` is found automatically, and its
fixtures are located by mirroring the schema path:

```
contracts/observations/location/location_fix/1.0.0.json
contracts/fixtures/observations/location/location_fix/{valid,invalid}.json
```

Adding a contract means adding fixtures, not editing tests. Each fixture is
`{ "case": "...", "why": "...", "instance": { ... } }`; `why` is required on invalid cases so a
rejection always records the rule it exists to pin down.

Beyond the fixtures, the suite enforces properties across *all* contracts: `$id` mirrors the file
path, every schema carries a real title and description, object schemas are closed
(`additionalProperties: false`), and every contract has both valid and invalid fixtures.

**The negative fixtures are the real contract.** A schema is defined by what it rejects, so each
invalid case must also fail on exactly *one* JSON path — a case that trips unrelated rules tests
nothing in particular and will keep passing after the rule it was written for is deleted. Paths
rather than error counts, because one conceptual violation often trips several keywords at once (a
malformed URI fails both `format` and `pattern`). Where a violation genuinely spans several fields,
the fixture declares them:

```json
{ "case": "region_only but coordinates present",
  "why": "...",
  "expect_paths": ["$.latitude", "$.longitude"],
  "instance": { }}
```

## A note on dependencies

`rfc3339-validator` and `rfc3986-validator` (both MIT) enable the `date-time` and `uri` format
checkers. The usual choice for `uri` is `rfc3987`, which is **GPLv3+** and therefore excluded by the
ADR-0009 dependency allow-list.

Where a `format` keyword and a `pattern` overlap in a contract, **the pattern is normative**: JSON
Schema's format vocabulary is optional and unevenly supported, and the Elixir server, the Dart client
and this package do not agree on which formats they check.

## The OpenAPI spec

`tests/test_openapi.py` validates `contracts/api/ingest/v1.yaml` against OpenAPI 3.1 and then checks
that the promises its prose makes are actually encoded: that upload returns 200 rather than 201,
that every outcome class is reported, that quarantine reasons distinguish a recoverable version lag
from a contract defect, that the watermark takes its device from the token rather than a parameter,
and that enrollment agrees with the envelope on what a pseudonym is.

A spec can validate cleanly while having quietly lost its semantics, so structural validation alone
would not be worth much.
