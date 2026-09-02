# 0001 — Make the tick interval a real unit, not a day in disguise

**Status:** backlog
**Filed:** 2026-09-02
**Touches:** `models/src/starsim_epidemica/twin.py`, `server/lib/epidemica_server/studies.ex`,
`server/lib/epidemica_server/epigame/rules.ex`, `apps/epigames/lib/src/game_state.dart`

## The problem

`twin.tick_interval_seconds` is in the bundle contract with a minimum of 60, and a study can set it
to an hour today. The server would accept it, compute the right periods, and produce results that
are quietly wrong: the transmission engine advances the epidemic a full day on every tick regardless
of what the interval says.

An hourly study would therefore run 24 days of epidemic per calendar day, and nothing would report
an error.

## Why it matters

Not for Epigames — a daily rhythm is right for a seven-day game, and a participant told their state
changes hourly would check their phone all day, which is a behavioural intervention nobody
consented to. It matters because the platform claims the interval is configurable, and a
configuration option that produces plausible wrong answers is worse than one that does not exist.

The likely real use is a shorter tick for a dense, short study — a conference day, a ward shift —
where a daily resolution loses the thing being measured.

## What is already in place

Threaded correctly:

- `Twin.period/4` reads `tick_interval_seconds` and derives the window from it.
- `Epigame.award_carry_over` reads it for the look-back window.
- `protection_window_seconds` is real time already, so protection would behave.
- **Rate parameters would rescale themselves.** `beta` is `ss.perday(x)` and `dur_inf` is
  `ss.days(n)`, both explicit since the units fix in W4. Change `dt` and Starsim converts them; had
  they been bare numbers every parameter would have silently changed meaning instead.

## What actually blocks it

1. **`models/src/starsim_epidemica/twin.py` pins the timestep.**

   ```python
   dur=ss.days(2),
   dt=ss.days(1),
   ```

   Both need to come from the interval. `dur` only has to be long enough to contain one step. This
   is the change that makes the difference between "configurable" and "silently wrong".

2. **`Studies.day_at/3` defaults to `interval \\ 86_400`,** and neither `running?/2` nor
   `Mix.Tasks.Epidemica.Tick.catch_up_days/1` passes the bundle's value. A short-tick study would
   compute the wrong current day, so actions would be accepted or refused against the wrong window
   and catch-up would run the wrong number of ticks.

3. **Two rule constants are named in days but counted in ticks.** `contact_cooldown_days` and
   `carry_over_days` are compared against tick indices, so they would behave correctly and
   *describe* themselves incorrectly. Renaming them is a contract change; leaving them is a trap for
   whoever writes the second study.

4. Cosmetic, but participant-facing: the app says "Day 3 of 7" and reports staleness in
   minutes/hours/days. Both need to follow the study's unit or they will contradict the screen.

## The constraint that actually decides the floor

**The tick interval must be comfortably longer than the sync interval.** A tick freezes its network
at `received_before`, and `sync.min_interval_seconds` is 900 in `epigame7`. A ten-minute tick would
settle most periods before the observations describing them had arrived: contacts would survive via
carry-over, but *transmission* for that tick would run on an empty network and the epidemic would
simply not spread.

So a shorter tick is not only a code change — it forces the sync interval down with it, which costs
battery and cellular data on every device in the study. An hour is comfortable. Ten minutes needs
the whole pipeline reconsidered, not just `dt`.

Worth encoding as a validation: refuse a bundle whose `tick_interval_seconds` is not at least a
small multiple of `sync.min_interval_seconds`, rather than letting a study discover it in the field.

## How it would be verified

- A `twin.py` test that an hourly tick advances the recovery clock by an hour, not a day — seed an
  agent with a known `recovers_on_day`, tick, and assert the offset. The existing `TestUnits` group
  is the place; it already pins the day case.
- A chained test at a non-daily interval that still produces an epidemic which grows and burns out.
  A wrong `dt` shows up here as an epidemic that resolves 24× too fast.
- An Elixir test that `day_at` and `running?` agree with `Twin.period` for a non-daily study. These
  three deriving the same boundary independently is the actual invariant.
- Seeded defects worth confirming are caught: `dt` left at one day; `day_at` left at 86 400;
  cooldown compared against seconds rather than ticks.

## Not in scope

Sub-minute ticks. The contract's minimum of 60 is generous already, and below that the subprocess
launch cost (~1.5 s of Starsim import per tick) dominates the interval.
