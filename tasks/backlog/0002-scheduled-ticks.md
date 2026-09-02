# 0002 — Ticks do not run on their own

**Status:** backlog
**Filed:** 2026-09-02
**Touches:** `server/config/config.exs`, `server/lib/epidemica_server/twin/worker.ex`,
`server/lib/epidemica_server/ops.ex` (new)

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
