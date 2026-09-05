# 0002 — Ticks do not run on their own

**Status:** done
**Filed:** 2026-09-02
**Landed:** 2026-09-05
**Touches:** `server/config/config.exs`, `server/lib/epidemica_server/twin/worker.ex`,
`server/lib/epidemica_server/ops.ex` (new)

## What was built, and where it differs from this plan

A `Twin.Scheduler` worker, run hourly by `Oban.Plugins.Cron`, that decides which twin study-days
are due and enqueues them. `Twin.Worker` and `Epigame.Worker` were already idempotent as this task
described — a day already run returns `already_run` and is treated as success — so the scheduler
itself is a decision, not an actor: it answers "what should run" rather than running it, which is
what makes running it twice safe by construction rather than by discipline.

**The buffer, and why it is not a guess.** A tick freezes its network at `received_before`, and a
phone syncs on its own schedule, so a tick that fires the moment a day ends settles it before the
last uploads land. The lag is derived from `sync.min_interval_seconds` when the study declares one,
and from a fixed 30-minute default when it does not — the task's own instruction, implemented rather
than approximated. This is the load-bearing constraint this task shares with
[`0001`](../backlog/0001-configurable-tick-interval.md): both are really about when a day's data has
finished arriving.

**`Ops`** exists as this task asked — a small module of named operator entry points for
`bin/epidemica_server eval` — because a host cron entry inlining multi-line Elixir is exactly the
kind of thing that is wrong under pressure and nobody finds afterwards.

## What was deliberately left undone

The multi-node trap is documented, not closed: two nodes would each run their own scheduler, and
`Oban.Plugins.Cron`'s leadership would prevent both from firing, but the unique-index catch that
makes a duplicate tick harmless would still show up as a silent failure in the losing node's logs.
Until a deployment actually runs more than one node, that is a documented constraint rather than a
bug — the same posture the task file itself takes. The `0001` interaction (both tasks are really
about when a day's data has finished arriving) is likewise noted rather than resolved; resolving
configurable tick intervals is [task 0001](../backlog/0001-configurable-tick-interval.md)'s own job,
not this one's.

## The problem

Oban is configured with a `twin` queue, and `Twin.Worker` and `Epigame.Worker` both exist and both
work. Nothing ever enqueues them. In development the days are driven by
`mix epidemica.tick`; in a release there is no Mix, so there is nothing at all.

A study deployed today collects observations correctly and never advances. On a participant's
phone that is indistinguishable from a study where nothing is happening, which is the failure mode
this whole area keeps producing.

## Why it matters

It is the last thing between a deployed server and an unattended study. The AWS instructions
currently work around it with a host cron entry that `eval`s two function calls, which is fragile
in the obvious ways: it hardcodes a study id, it has no retry beyond the next day, and it lives
outside the repository where nobody will find it.

## What is already in place

- `Twin.Worker` and `Epigame.Worker`, both idempotent. A day already run returns
  `{:error, :already_run}`; already settled returns `{:error, :already_settled}`. Both are treated
  as success, so re-running is safe by construction.
- `Twin.Worker` already enqueues settlement after a successful tick, so only the tick needs
  scheduling.
- `Studies.day_at/3` returns the current study-day, or `nil` before the study opens and after it
  ends — a total function over time, which is exactly what a scheduler needs.
- `Studies.running?/2`.

## What needs doing

1. **A job that decides what is due.** Something like `Twin.Scheduler`, run periodically: for every
   open study with a `twin` block, ask `Studies.day_at/1`, and enqueue any day from 1 to that which
   has no tick yet. Enqueueing an already-run day is harmless, so the query does not have to be
   clever — but it should be, or a long study re-enqueues its whole history every hour.

2. **`Oban.Plugins.Cron`** in `config/config.exs` to run it. Hourly is plenty for a daily tick and
   gives a study fourteen chances to recover from a transient failure before the day is missed.

3. **A delay after the boundary.** A tick freezes its network at `received_before`, and phones sync
   every 15 minutes. Ticking at the instant a day ends settles it before the last uploads land.
   Half an hour is a reasonable default; it should be derived from `sync.min_interval_seconds`
   rather than guessed, and it interacts with
   [`0001`](0001-configurable-tick-interval.md) — both are really the same constraint about data
   arrival.

4. **`EpidemicaServer.Ops`**, a small module of operator entry points callable from
   `bin/epidemica_server eval`: `catch_up/1`, `status/1`. The AWS runbook currently inlines
   multi-line Elixir into a cron entry, which is not something anyone should have to get right
   under pressure.

## The multi-node trap

The `twin` queue is `[twin: 1]` — one job per **node**, not per cluster. Two nodes will run ticks
concurrently. For different studies that is fine and desirable; for the same study-day the unique
index on `twin_ticks (study_id, day)` means the loser fails and rolls back, so nothing is
corrupted.

But relying on a database constraint to paper over a scheduling error means the failure is silent
in the losing node's logs. If the deployment ever scales past one node, the scheduler needs
`Oban.Plugins.Cron`'s leadership (it only runs on the leader) *and* unique job options on the
worker.

Until then: **desired count 1.** This is noted in the AWS instructions.

## How it would be verified

- A test that the scheduler enqueues exactly the missing days for a study mid-run, and nothing for
  a study that has not started or has ended.
- A test that running the scheduler twice does not double-enqueue — `Oban.Testing` with
  `assert_enqueued` counts.
- A test that a study with no `twin` block is never scheduled.
- Seeded defects worth confirming are caught: enqueueing day 0; enqueueing past the study's last
  day; enqueueing before `starts_at`; scheduling a collection-only study.

Oban's testing mode is already `:manual` in `config/test.exs`, so jobs can be asserted without a
queue running.
