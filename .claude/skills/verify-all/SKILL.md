---
name: verify-all
description: Run the full Epidemica verification sweep across Elixir, Python and Dart, and interpret the results. Use before claiming any change is complete, after merging, or when asked whether the repository is green.
---

# Verify all

Six suites in three languages. Run them all before saying a change is done. Expected counts are
below — a suite that reports fewer tests than expected has probably failed to collect, which looks
like success in a summary line.

## Run

```sh
cd server   && mix format --check-formatted && mix compile --warnings-as-errors && mix test
cd models   && uv run pytest -q
cd analysis && uv run pytest -q
flutter analyze apps packages
for p in packages/epidemica_core packages/epidemica_survey packages/epidemica_proximity apps/epigames; do
  printf "%-34s " "$p"; (cd "$p" && flutter test 2>&1 | tail -1)
done
```

## Expected

| Suite | Tests |
|---|---|
| `server` | 271 |
| `models` | 64 |
| `analysis` | 456 passed, 1 skipped |
| `packages/epidemica_core` | 115 |
| `packages/epidemica_survey` | 27 |
| `packages/epidemica_proximity` | 34 |
| `apps/epigames` | 48 |

`flutter analyze` must report **zero** issues. These counts drift upward as tests are added; update
this table when they do, and be suspicious when they drift *down*.

## Preconditions

- Postgres running: `brew services start postgresql@14`. Without it the server suite fails on
  connection, not on logic.
- `uv` resolves `models/` and `analysis/` as separate environments. Running pytest from the wrong
  directory collects nothing and exits 0.

## Reading failures

**`mix format --check-formatted` fails** — run `mix format` on the files you changed. Do not run it
repository-wide.

**Warnings as errors** — an unused variable or alias fails the build. That is deliberate; fix it
rather than relaxing the flag.

**Contract tests fail after adding a schema** — you are missing fixtures, a `why` on an invalid
fixture, or the invalid fixture trips more than one rule. See `contracts/AGENTS.md`.

**A Dart test makes a real network call** — a test helper lost its injected client. Check that the
constructor still receives `httpClient:`.

**A test fails that you did not touch** — do not weaken it. Work out which of the two is wrong and
say which, before changing either.
