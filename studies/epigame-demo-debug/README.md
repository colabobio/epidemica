# Epigame: open-ended debug

The open-ended game, compressed into continuous three-minute rounds, for checking that the pipeline
works without waiting a real day.

Same shape as [`epigame-demo`](../epigame-demo) — no last day, turnover, grace period — with the
intervals shortened so the whole arc runs in real time rather than over days. **It is a debugging
instrument, not a study.** Nothing it produces is an epidemiological result.

## What is different, and why each change is forced

| Setting | `epigame-demo` | here | Why |
|---|---|---|---|
| `twin.tick_interval_seconds` | 86 400 | **180** | A round every three minutes. |
| `health.interval_seconds` | 3600 | **60** | **Mandatory.** See below. |
| `sync.min_interval_seconds` | 900 | **60** | Consistency only — nothing reads it yet. |
| `rules.pars.contact_min_seconds` | 600 | **120** | 600 s rarely clears inside a 180 s window. |
| `rules.pars.protection_window_seconds` | 86 400 | **300** | Protection must last one round, not 288 of them. |
| `twin.turnover_after_days` | 30 | **5** | A virtual agent lives five rounds, so turnover is visible in one sitting. |
| `twin.finished_grace_days` | 2 | **1** | A participant who finishes gets one round to see it, not two days. |
| `twin.population` | 100 | **20** | A small cohort is enough to watch the epidemic move; more is noise. |

Everything else — `beta`, `dur_inf_days`, the virtual mixing, every point value — is deliberately
identical, so what you observe here is the same game.

### The health interval is not optional

This is the failure that made the first field test look broken, and shortening the tick without
shortening this reproduces it immediately.

Coverage is asserted positively: a `module_status` observation claims `[window_start, window_end]`
was spent sensing, and a period with no report is *uncovered*. The twin requires coverage of at
least `coverage_threshold` (0.5) **of the tick period**, and anyone below it is treated as protected
and their round is scored `not_sensing` — 0 points, no contacts, no transmission.

The reporter emits its first window one interval after collection starts. At 3600 s with a 180 s
tick, every round would close before the first coverage report existed. Every player would be
`not_sensing` for the entire run, the epidemic would not spread, and nothing would report an error.

At 60 s you get about three reports per round, so coverage is complete and the run means something.

**The general rule: `health.interval_seconds` must be comfortably shorter than
`twin.tick_interval_seconds`.** Here it is a third.

## What this is for

Checking that an open-ended study actually runs: that days keep being offered, that a finished
participant is removed and told, that a dead agent's slot is refilled, that an outbreak that dies
out is re-seeded. Run it alongside [`epigame-debug`](../epigame-debug) — the seven-day game,
compressed — to compare the two shapes against the same real devices.
