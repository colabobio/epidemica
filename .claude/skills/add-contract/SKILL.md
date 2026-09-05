---
name: add-contract
description: Add or version a JSON Schema contract in the Epidemica repository, with the fixtures the test harness requires. Use when defining a new observation type, instrument, bundle section or state document, or when changing an existing schema.
---

# Add a contract

A contract is the agreement between the Elixir server, the Dart clients and the Python analysis. The
harness in `analysis/tests/test_contracts.py` discovers schemas automatically — you add files, not
test cases.

## Files

```
contracts/<area>/<name>/<major.minor.patch>.json
contracts/fixtures/<area>/<name>/<version>/valid.json
contracts/fixtures/<area>/<name>/<version>/invalid.json
```

## The schema

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://schemas.epidemica.info/<area>/<name>/<version>.json",
  "title": "Short noun phrase",
  "description": "More than forty characters, saying what this is for and when it is produced.",
  "type": "object",
  "additionalProperties": false,
  "required": ["..."],
  "properties": { }
}
```

- **`$id` must mirror the file path** so a URI resolves offline from the repository.
- **`additionalProperties: false` on every object**, nested ones included. A module must not be able
  to ship a field nobody agreed to store.
- **Describe every property.** The description is the contract; the type is only its enforcement.

## The fixtures

`valid.json` is a realistic complete instance — not a minimal one. It is documentation as much as a
test.

`invalid.json` must:

- carry a **`why`** field naming the rule it pins down;
- be built by mutating the **valid** fixture, so the only difference is the violation;
- fail on **exactly one** JSON path. A fixture that trips several rules is testing nothing in
  particular and will keep passing after the rule it was written for is deleted. If a violation
  genuinely spans fields, declare `expect_paths`.

## Verify

```sh
cd analysis && uv run pytest -q tests/test_contracts.py
```

Then teeth-check the fixture: remove the violation from `invalid.json` and confirm the suite fails.
A fixture that passes both ways is not constraining anything.

## Versioning

Never change what an existing version means — data already collected under it becomes
uninterpretable. Add a new version and keep the old one and its fixtures.

If a reader must accept both, keep the fallback and test it. Stored documents are re-run to verify
them, and a document that stops being readable stops being verifiable.

## What schemas cannot say

Constraints like "these array entries must have distinct names" are not expressible. Enforce them in
code, and note in both places that the other exists.

## Not a schema

`*.vectors.json` files are shared test data run by more than one implementation. **They must not
have an `$id`** — the discovery helper treats anything with one as a schema and will demand
fixtures. Use `comment`.
