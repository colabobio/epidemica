# AGENTS.md

Epidemica: contracts plus reference implementations for collecting epidemiological data from
mobile devices and running interventions over it. Elixir server, Flutter/Dart client packages,
Python simulation and analysis, JSON Schema contracts binding them together.

Read [`docs/concepts/`](docs/concepts/) before changing behaviour. Those documents explain *why*
things are the way they are; this file covers how to work here without breaking them.

## Verify before you claim

Six suites in three languages. Run the ones you touched, and the whole sweep before saying you are
done:

```sh
cd server   && mix format --check-formatted && mix compile --warnings-as-errors && mix test
cd models   && uv run pytest -q
cd analysis && uv run pytest -q
flutter analyze apps packages
cd packages/epidemica_core     && flutter test
cd packages/epidemica_survey   && flutter test
cd packages/epidemica_proximity && flutter test
cd apps/epigames               && flutter test
```

`mix compile --warnings-as-errors` is not optional: warnings are errors in this repo, and a change
that compiles with warnings is not finished. `flutter analyze` must report **zero** issues.

Postgres must be running for the server suite (`brew services start postgresql@14`).

## Conventions that are not negotiable

**Every fix gets a teeth check.** Write the test, then re-introduce the defect and confirm the test
fails. A test that passes against the bug is not a test. See the `teeth-check` skill.

**Comments say what the code cannot.** State the reason, the trap, or the consequence — never
restate the line below. No multi-paragraph doc comments where one line will do, and no comments
narrating the change for a reviewer.

**Contracts are closed.** `additionalProperties: false`, `$id` mirrors the file path, a title and a
description over 40 characters. Every schema needs valid *and* invalid fixtures. See
[`contracts/AGENTS.md`](contracts/AGENTS.md).

**Lockfiles are committed in every language.** A published dataset has to stay re-derivable years
later.

## Traps that have actually bitten

These are real failures from this codebase, not hypotheticals.

**Starsim defaults are year-scaled, and an inherited default prints the same repr as an explicit
day-scaled value.** `ss.SIR()` defaults `beta` to `peryear(0.1)`. Always state time-valued
parameters explicitly: `ss.perday(x)`, `ss.days(n)`. See [`models/AGENTS.md`](models/AGENTS.md).

**A tick is immutable and a wrong one is permanent.** `twin_ticks` has a unique index on
`(study_id, day)`. Deciding a day that has not finished settles it on data that does not exist yet.
`mix epidemica.reset_study` is the only recovery, and it throws the whole run away.

**Promptness is correctness once a twin exists.** A tick freezes the record at `received_before`.
Observations arriving later enter the store and every later analysis but **never affect
transmission**. Scoring can carry over; the epidemiology cannot.

**Coverage thresholds are a fraction of the tick period.** `0.5` over a day means twelve hours of
asserted sensing. Shorten the tick without shortening `health.interval_seconds` and every
participant reads as `not_sensing` — with no error anywhere.

**A base URI without a trailing slash silently drops the API prefix.** `Uri.resolve` treats
`.../v1` as naming a file. The server then 404s and the app reports "unknown join code".

**Some facts are the study's conclusions; some are the participant's or the device's.** A settled
score and a coverage judgement are conclusions, published once and never revised. Whether
protection is running *now*, or the radio is on *now*, is present-tense and must come from the
participant or the device. Reading one as the other causes a whole class of bug here.

**The bundle's `study_id` is not the study id.** The server generates its own and never reads the
bundle's — see [`tasks/backlog/0005`](tasks/backlog/0005-bundle-study-id-is-not-the-study-id.md).

## Do not

- **Do not `git checkout --` to undo a temporary edit.** It discards uncommitted work in that file.
  Back up with `cp` first, restore from the backup, then re-run the tests to confirm the restore was
  clean. This has already cost real work.
- **Do not run a formatter across files you did not change.** `dart format <dir>` reflows unrelated
  files and buries the real diff. Format only what you touched.
- **Do not use `sed`/`perl` for multi-line edits in test files.** They silently drop lines. Use an
  editing tool and read the result.
- **Do not add a field to a contract without fixtures**, or an invalid fixture without a `why`.
- **Do not weaken a test to make it pass.** If a test fails after a change, decide which one is
  wrong and say so.

## Where things are

`contracts/` schemas and fixtures · `server/` Phoenix + Postgres · `models/` Starsim twin ·
`analysis/` contract tests and analysis · `packages/` Dart client packages · `apps/` study apps ·
`studies/` authored bundles · `docs/adr/` decisions · `docs/concepts/` how it works ·
`tasks/` known work, with the investigation already done.

Nested `AGENTS.md` files in `contracts/`, `server/`, `models/` and `packages/` carry the local
rules. The nearest one wins.
