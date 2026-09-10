# 0002 — Ticks do not run on their own

**Status:** done
**Filed:** 2026-09-02
**Landed:** 2026-09-09
**Touches:** `server/config/config.exs`, `server/lib/epidemica_server/twin/scheduler.ex` (new),
`server/lib/epidemica_server/twin/worker.ex`, `server/lib/epidemica_server/ops.ex` (new)

## What was built, and where it differs from the plan below

`Twin.Scheduler`, run hourly by `Oban.Plugins.Cron`, decides which study-days are due and enqueues
them. It is a *decision*, not an actor: `due_ticks/1` answers "what should run" and returns pairs,
so a test can assert the answer without asserting anything about Oban, and running it twice is safe
by construction rather than by discipline.

Four things are worth recording because they are not obvious from the plan:

**Which days exist is asked in one place.** `due_for/2` is built on `Studies.days_to_catch_up/2`,
the same function `Ops.catch_up/1` and `mix epidemica.tick --catch-up` use. A scheduler with its own
notion of "has this study started, is it over" would eventually disagree with the task that operators
reach for when it goes wrong.

**The buffer applies to a finished study's last day too.** An earlier cut special-cased an ended
study and offered every day at once. But *over* is not *finished arriving*: day 7 ending is exactly
when the buffer matters most, because there is no day 8 whose tick would pick up the stragglers.
One rule, applied uniformly.

**`Twin.Worker` is now unique across the live job states.** The scheduler keeps finding a day due
until a tick row exists, so a day whose tick cannot run — an engine that will not start being the
obvious case — would have accumulated one job an hour, indefinitely. Uniqueness covers
`available`, `scheduled`, `executing` and `retryable` only: once every attempt is spent the job is
discarded, and an operator who has fixed the cause can enqueue it again.

**The scheduler runs in its own queue.** Sharing `twin` (limit 1) would put the hourly decision
behind whatever ticks are already queued, so a study catching up on a week would stop noticing new
days while it worked.

**Cron is `:prod` only.** In dev it would fire immutable ticks mid-inspection, which is the opposite
of what [`studies/epigame-debug`](../../studies/epigame-debug/README.md) exists for. Test disables
Oban outright.

## What was deliberately left undone

The multi-node trap is documented, not closed. `Oban.Plugins.Cron` elects a leader, so two nodes
would not both schedule — but the `twin` queue's limit of one is per node, so a job enqueued outside
the scheduler could still tick the same study twice. The unique index on `twin_ticks (study_id, day)`
makes that harmless rather than corrupting, and the loser fails silently in its own logs. Until a
deployment runs more than one node this stays a documented constraint.

`Twin.Worker` still burns all five attempts on a premature day rather than snoozing until
`period_end`. The scheduler's buffer means it never hands one over, so this is now only reachable
by a manual enqueue — noted in [epigame.md](../../docs/concepts/epigame.md), still worth fixing.

The interaction with [`0001`](../backlog/0001-configurable-tick-interval.md) is noted, not resolved:
both tasks are really about when a day's data has finished arriving.

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
   [`0001`](../backlog/0001-configurable-tick-interval.md) — both are really the same constraint about data
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
