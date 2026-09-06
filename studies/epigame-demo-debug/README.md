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

---

# Step-by-step: debugging Epigames

Two phones, about 45 minutes. Read the whole sequence before starting — step 3 is the one people
skip.

## 0. Before you start

```sh
cd server && mix test          # 287 tests
cd ../models && uv run pytest  # 64 tests
```

Check the phones: Bluetooth on, permissions granted, both on the **same Wi-Fi as your laptop**, neither in Low Power Mode.

## 1. Start the server and register the study

```sh
START="$(date -u -v+10M +%Y-%m-%dT%H:%M:%SZ)" \
  BUNDLE=studies/epigame-demo-debug/bundle.json \
  deploy/local/epigames/up.sh
```

Note the two things it prints: the server's LAN address and the **server-generated study id** (not the bundle's `study_id`, which is unused — task 0005). Save both:

```sh
export STUDY=<STUDY_ID>
```

## 2. Install on both phones

```sh
cd apps/epigames
flutter run --dart-define=EPIDEMICA_SERVER=http://<LAN-IP>:4000/v1/
```

**The trailing slash is required.** Without it the app resolves against the host root and reports the resulting 404 as "That code did not match an open study" (task 0004).

Join both phones with `EPIGAME-DEMO-DEBUG`.

## 3. Let it collect before you tick anything

**Wait until at least two rounds have passed** — six minutes after `starts_at` — with both phones near each other and unlocked.

Confirm both observation types exist before going further:

```sh
psql epidemica_server_dev -c "
SELECT module, schema_uri, count(*), min(received_at), max(received_at)
FROM observations WHERE study_id = '$STUDY' GROUP BY 1,2;"
```

You want **two** rows — `contact_episode` and `module_status` — with counts on both. If `module_status` is missing, health reporting never started. If `contact_episode` is missing, the phones are not seeing each other.

## 4. Run the rounds

```sh
cd server && mix epidemica.tick --study $STUDY --catch-up
```

`--catch-up` runs every round that has **finished** and stops. It will not run the round in progress — `ensure_elapsed` refuses to settle a window whose data has not finished arriving. Expected output:

```
day 1:
  twin      ok
  settle    ok
day 2:
  twin      ok
  settle    ok
```

`refused, that day has not finished yet` on the last round is **correct** — wait for the clock. Re-run every few minutes, or leave it running:

```sh
watch -n 60 "mix epidemica.tick --study $STUDY --catch-up"
```

## 5. Check what the round decided

```sh
psql epidemica_server_dev -c "
SELECT day, period_start, period_end,
       jsonb_array_length(inputs->'contacts') AS edges,
       outputs->>'newly_infected' AS new_cases,
       outputs->>'total_cases'    AS total
FROM twin_ticks WHERE study_id = '$STUDY' ORDER BY day;"
```

`edges: 0` on a round where you know the phones were together means the observations had not arrived before the tick's cutoff. Check `received_at` against `period_end`.

## 6. The open-ended-specific thing to watch for

Unlike `epigame-debug`, this study has no last day. The scheduler will keep offering days forever, and the outbreak will eventually burn out — which is the point of the re-seeding logic. What you want to see is:

- **Days keep being offered** as long as the study is open, with no ceiling.
- **A finished participant** (recovered or dead) is removed from the roster after one round of grace and shown "Finished" in the app, rather than staying in the sim indefinitely.
- **When the outbreak dies out** — every susceptible recovered or dead — the next tick re-seeds it from the study's own `seed` block, so the demo keeps running rather than quietly ending. Check `outputs->>'newly_infected'` jumping back above zero after a stretch of zeros.

## 7. Replay

To run the whole arc again against the **same real contact data**:

```sh
mix epidemica.reset_study --study $STUDY
mix epidemica.tick --study $STUDY --catch-up
```

That clears ticks, agents, ledger, awards and published state. It **keeps** every observation and every protection decision — a replay that dropped them would score a different game from the one that was played. The seed is derived from `{study_id, day}`, so a replay with unchanged parameters produces identical results.

## What's different from epigame-debug

- **No final round.** There is no round 7 to reach; the study ends when you close it, not when the calendar says so.
- **No "GAME OVER" for the study as a whole.** Individual participants see "Finished" when their grace period elapses; the study itself never ends.
- **The re-seeding test is the point.** A finite study whose epidemic dies out is a completed experiment; an open-ended one whose epidemic dies out and never re-seeds is a broken demo. Watch for the re-seed, not for a final score.