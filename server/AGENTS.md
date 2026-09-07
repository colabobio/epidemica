# server/AGENTS.md

Phoenix and Postgres. Ingest, projections, the twin runtime, scoring, and the participant state
channel.

```sh
mix format --check-formatted && mix compile --warnings-as-errors && mix test
mix ecto.reset                      # drop, create, migrate — needs Postgres running
mix epidemica.seed_study --bundle studies/<name>/bundle.json
mix epidemica.tick --study <id> --catch-up
mix epidemica.reset_study --study <id>    # clears derived state, keeps observations
```

Warnings are errors. A change that compiles with warnings is not finished.

## Immutability is the point

A **tick** is written once — `twin_ticks` is unique on `(study_id, day)` — because participants are
told its result. Re-running a stored tick is *verification* against its recorded inputs and seed,
never replacement. A **settled day** is the same: a contact whose other side arrives later is
credited to the next settlement rather than rewriting one a participant has already seen.

Two guards exist because both failures happened:

- `ensure_in_schedule` — no day 0, no day past the end.
- `ensure_elapsed` — a day still in progress, or in the future, cannot be decided. `--force` and
  `allow_incomplete: true` override it for demonstrations and tests.

## Judge every day by the facts that held on it

`award_carry_over` recomputes coverage **and** chosen protection for each earlier day it revisits.
Using today's protection paid participants for contacts made while protected — refunding a cost they
had accepted — and the mirror case denied contacts already earned. If you revisit a past day, ask
what was true *then*.

## One resolver for rules

`Rules.pars_for(rules, arm)` is defaults + the study's `pars` + the participant's arm. Every caller
that asks "what are the rules" asks it there, so nothing can score someone against the wrong group.
Do not add a parallel path.

## Observations are the system of record

Everything else is derived and rebuildable. `Projections.rebuild_contacts/1` must reproduce exactly
what incremental projection produced — that property is what makes the observation store the single
source of truth rather than one copy among several.

Ingest projects inline: an empty `contacts` table is indistinguishable from a study where nobody met
anyone, so a projection that only runs when something asks for it is a silent wrong answer.

## Study-level questions have one owner

`Studies.tick_interval/1` is the single definition of how long a day is. `day_at`, `running?`,
`Twin.period/4` and `award_carry_over` all read it. Two implementations of "which day is it" drift,
and the drift is hardest to see exactly when it matters.

## Publishing to participants

`ParticipantState.put/5` validates against the study's state contract before writing. A failed
validation rolls the settlement back: settling a day and failing to tell the participant is worse
than not settling it, and a run that fails identically next time is the right noise for a bug in
what a study publishes.
