# contracts/AGENTS.md

JSON Schemas that bind the Elixir server, the Dart clients and the Python analysis together. A
contract is the agreement; the implementations are negotiable.

## The rules the test harness enforces

[`analysis/tests/test_contracts.py`](../analysis/tests/test_contracts.py) discovers every schema
automatically. Adding a contract means adding fixtures, not editing that file.

- **`$id` mirrors the path.** `contracts/foo/bar/1.0.0.json` →
  `https://schemas.epidemica.info/foo/bar/1.0.0.json`, so a URI resolves offline from the repo.
- **`title`, and a `description` over 40 characters.**
- **Object schemas are closed.** `additionalProperties: false`, so a module cannot ship a field
  nobody agreed to store.
- **Valid *and* invalid fixtures**, mirrored under `contracts/fixtures/<same path>/`.
- **Every invalid fixture carries a `why`** saying which rule it pins down.
- **An invalid fixture must fail on exactly one JSON path.** A fixture that trips unrelated rules
  is testing nothing in particular and will keep passing after the rule it was written for is
  deleted. If a violation genuinely spans fields, declare `expect_paths`.

That last rule is the one that catches sloppy fixtures: build an invalid case from a **valid** base,
or it will fail for the wrong reason.

## Vectors files are not schemas

`contracts/game/epigame_rules/1.0.0.vectors.json` is shared test data run by both Elixir and Dart,
so the two implementations cannot drift. **It must not have an `$id`** — the discovery helper treats
anything with one as a schema and will demand fixtures for it. Use `comment` instead.

## What cannot be expressed here

JSON Schema cannot say "these array entries must have distinct names". Rules like that are enforced
in code — for example duplicate arm names in `Rules.arms/1`. If a constraint cannot be schematised,
enforce it where it can be and say so in both places.

## Versioning

A contract version is a promise. Changing what a version *means* breaks data already collected
under it. Add a new version instead; the old one stays for the record.
