# 0009 — Seeding a taken join code produces a study nobody can join

**Status:** backlog
**Filed:** 2026-09-04
**Touches:** `server/lib/mix/tasks/epidemica.seed_study.ex`, `server/lib/epidemica_server/studies.ex`

## The problem

`epidemica.seed_study` creates the study first and attaches the join code afterwards, and treats
failure to attach it as a note rather than an error:

```elixir
case Studies.add_join_code(study, code, opts[:arm]) do
  {:ok, _} -> Mix.shell().info("Join code: #{code}")
  {:error, _} -> Mix.shell().info("Join code #{code} already exists")
end
```

`join_codes.code` is unique across the whole table, not per study. So if the code already belongs to
a **different** study, the new study is created, keeps its instruments and its protocol, prints its
id — and has no way in. The task then goes on to print the usual success block, including a
`flutter run` line, as though everything worked.

The message is also wrong about what happened. "Already exists" reads as *"you have already
registered this, nothing to do"*, which is exactly the benign case it is not.

## How it showed up

Registering the debug study twice with different start times, which is ordinary during development:

```
Created study 29040e8f-b2cf-4e0b-95fd-d45f32f17155
Join code EPIGAME-DEBUG already exists
Instrument: checkin@1.0.0
```

Three studies existed; `EPIGAME-DEBUG` still pointed at the first. Enrolling with it produced a
token for the *old* study, which then 404ed on the new study's instrument — a confusing symptom two
layers away from the cause, and one that could as easily have been diagnosed as a broken endpoint.

## Why it matters

The failure is silent in the direction that matters. An operator seeding a study for a field session
gets a study id, a protocol hash and instructions, and only discovers the study is unreachable when
the first participant cannot join — typically in a room with people waiting.

It is also a data-integrity problem rather than only an inconvenience. Devices that join with that
code enrol in the *older* study, so observations land against a protocol nobody meant to be running,
and the two studies are only distinguishable afterwards by inspecting `protocol_hash`.

## What is already in place

- `Studies.add_join_code/3` already returns `{:error, changeset}` on the unique constraint, so the
  information is there and merely discarded.
- Seeding is already idempotent on `protocol_hash`: re-registering identical bytes finds the
  existing study rather than making a second one. The bug only bites when the bytes *differ* and the
  code does not.
- `Instruments.register/2` sets the precedent for the right behaviour — identical input is a no-op,
  conflicting input is a loud refusal rather than a shrug.

## What needs deciding

Whether the same code pointing at a new study should be an **error** or a **move**.

*Error* is the conservative reading: a code in use identifies a study, and silently repointing it
would send devices that scanned a poster last week into a different study. The operator picks a new
code, or retires the old study deliberately.

*Move* is the convenient one for development, where re-seeding a tweaked bundle under the same code
is exactly what is wanted, and the previous study is scrap. It is dangerous in production for the
reason above.

The likely answer is **error by default, with an explicit `--steal-code` or `--replace` for the
development case** — the same shape as `--force` on `epidemica.tick` and `--clear-actions` on
`epidemica.reset_study`: safe by default, with a way to say you meant it.

Two smaller points fall out:

- The study should not be left behind. Either create it inside the same transaction as the join
  code, or delete it on failure. A half-registered study with no way in is litter.
- `add_join_code/3` should distinguish "this study already has this code" (genuinely a no-op) from
  "another study has it" (the dangerous case). Right now both are one `{:error, changeset}`.

## How it would be verified

- Seeding a bundle whose code belongs to another study fails, names both studies, and leaves no new
  study behind.
- Seeding the *same* bundle twice with the same code stays a no-op, as now.
- Seeding a changed bundle with a fresh code succeeds and both studies are reachable.
- With the escape hatch, the code moves and the old study is reported as no longer joinable.
- A teeth check worth doing: restore the current behaviour and confirm the first test fails —
  ideally by asserting the study is *absent*, not merely that the task exited non-zero, since a
  version that errors after creating the study would otherwise pass.
