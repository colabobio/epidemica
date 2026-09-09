# studies/epigame-debug

The seven-day game, compressed into about half an hour, for checking that the pipeline works.

Same rules and same disease as [`epigame7`](../epigame7), with three intervals shortened so that a
full arc — join, sense, tick, settle, publish, protect, finish — happens in one sitting rather than
over a week. **It is a debugging instrument, not a study.** Nothing it produces is an
epidemiological result.

## Why this exists

A day-scale tick makes manual debugging almost impossible. Every tick is immutable, so a mistake is
permanent; a full arc takes a week; and a single wrong `--day` argument settles a day on data that
does not exist yet and cannot be undone. The first field test lost a day exactly that way.

This bundle plus [`mix epidemica.reset_study`](../../server/lib/mix/tasks/epidemica.reset_study.ex)
turns that into a loop: collect real contact data once with real phones, then replay the whole game
against it as many times as you like.

## What is different, and why each change is forced

| Setting | `epigame7` | here | Why |
|---|---|---|---|
| `twin.tick_interval_seconds` | 86 400 | **300** | Seven rounds in 35 minutes. |
| `health.interval_seconds` | 3600 | **60** | **Mandatory.** See below. |
| `sync.min_interval_seconds` | 900 | 60 | Consistency only — nothing reads it yet (see *Known gaps*). |
| `rules.pars.contact_min_seconds` | 600 | **120** | 600 s rarely clears inside a 300 s window. |
| `rules.pars.protection_window_seconds` | 86 400 | **300** | Protection must last one round, not 288 of them. |
| `modules.survey.instruments` | — | **two** | One anchored to enrollment, one to the study, so both clocks are exercised in one sitting. |

Everything else — `beta`, `dur_inf_days`, `population`, the virtual mixing, every point value — is
deliberately identical, so what you observe here is the same game.

### The health interval is not optional

This is the failure that made the first field test look broken, and shortening the tick without
shortening this reproduces it immediately.

Coverage is asserted positively: a `module_status` observation claims `[window_start, window_end]`
was spent sensing, and a period with no report is *uncovered*. The twin requires coverage of at
least `coverage_threshold` (0.5) **of the tick period**, and anyone below it is treated as protected
and their round is scored `not_sensing` — 0 points, no contacts, no transmission.

The reporter emits its first window one interval after collection starts. At 3600 s with a 300 s
tick, every one of the seven rounds would close before the first coverage report existed. Every
player would be `not_sensing` for the entire game, the epidemic would not spread, and nothing would
report an error.

At 60 s you get about five reports per round, so coverage is complete and the run means something.

**The general rule: `health.interval_seconds` must be comfortably shorter than
`twin.tick_interval_seconds`.** Here it is a fifth.

### Why the disease parameters do *not* change

`models/src/starsim_epidemica/twin.py` pins the engine's timestep:

```python
dur=ss.days(2),
dt=ss.days(1),
```

The tick interval sets the *window of observations* a round covers; it does **not** change how far
the epidemic advances. Every tick still advances one simulated day whatever the wall-clock interval.

That is [task 0001](../../tasks/backlog/0001-configurable-tick-interval.md), and for a real study it
is a genuine defect — an hourly study would run 24 days of epidemic per calendar day. **For
debugging it is exactly what you want**, and the reason to leave it alone:

- `dur_inf_days: 5` still means five rounds, so infections still resolve in the middle of a
  seven-round game.
- `beta: 0.35` still means per round.
- The epidemic curve is identical to the seven-day game, only compressed in wall-clock.

Fix `dt` first and every epidemiological parameter would need re-tuning to show anything in five
minutes — you would be debugging the plumbing and the model at once. Keep them separate.

**So: epidemiological time is deliberately decoupled from wall-clock time here.** One round is one
epidemic-day and five real minutes. Do not read a rate off this study.

### What a compressed run does not test

- The real 24-hour rhythm, and background sync across a day.
- Anything about day length being meaningful.
- iOS background execution over hours, app termination and relaunch.
- The first-hour coverage gap that `epigame7` genuinely has.

Everything mechanical is exercised: sensing, episode aggregation, upload, ingest, projection,
reconciliation, coverage, roster, seeding, transmission, settlement, carry-over, publishing,
protection in both its roles, and the app's rendering of all of it.

## Two other compressions worth knowing

**Episodes are not apportioned across rounds.** `Reconciliation.network/4` selects any episode
overlapping the window and counts its full duration. An episode is capped at 900 s — three rounds
here — so the same encounter can be counted in several consecutive rounds. Over a day-scale tick
this is a rounding error; at 300 s it is routine. `contact_cooldown_days: 1` (one *round*) keeps a
pair from being paid every round regardless.

**`contact_cooldown_days` and `carry_over_days` are counted in ticks, not days.** They are named in
days and compared against tick indices. Here that means one round and three rounds. This
mis-naming is [task 0001](../../tasks/backlog/0001-configurable-tick-interval.md) item 3.

---

# Step-by-step: debugging Epigames

Two phones, about 45 minutes. Read the whole sequence before starting — step 3 is the one people
skip.

## 0. Before you start

```sh
cd server && mix test          # 205 tests
cd ../models && uv run pytest  # 60 tests
```

If those are red, fix them first: a field test is a bad place to discover a unit-test failure.

Check the phones: Bluetooth on, permissions granted, both on the **same Wi-Fi as your laptop**, and
neither in Low Power Mode (iOS suspends BLE aggressively).

## 1. Start the server and register the study

Start the study **ten minutes in the future**, so both phones are joined and collecting before
round 1 opens:

```sh
START="$(date -u -v+10M +%Y-%m-%dT%H:%M:%SZ)" \
  BUNDLE=studies/epigame-debug/bundle.json \
  deploy/local/epigames/up.sh
```

On GNU coreutils use `date -u -d '+10 minutes' +%Y-%m-%dT%H:%M:%SZ`.

Do **not** use `TODAY=1` here. It anchors to the top of the current hour, and a 35-minute study
started at the top of the hour is usually over before you have installed anything.

**On every run after the first, add `STEAL_CODE=1`.** A new start time means new bundle bytes, so it
is a different study, and `EPIGAME-DEBUG` still belongs to the previous one. Seeding refuses rather
than leaving the code where it was:

```sh
STEAL_CODE=1 START="$(date -u -v+10M +%Y-%m-%dT%H:%M:%SZ)" \
  BUNDLE=studies/epigame-debug/bundle.json \
  deploy/local/epigames/up.sh
```

The phones are still enrolled in the old study, so leave the study on each before re-joining.
Otherwise they resume the previous enrolment from their own database and never see the new one.

Note the two things it prints:

```
==> Server is at http://192.168.x.x:4000
Created study <STUDY_ID>
Join code: EPIGAME-DEBUG
```

**Use the `Created study` id for every command below**, not the `study_id` in the bundle — they are
different, and the bundle's is not used
([task 0005](../../tasks/backlog/0005-bundle-study-id-is-not-the-study-id.md)).

```sh
export STUDY=<STUDY_ID>
```

## 2. Install on both phones

```sh
cd apps/epigames
flutter run --dart-define=EPIDEMICA_SERVER=http://192.168.x.x:4000/v1/
```

**The trailing slash is required.** Without it every request loses the `/v1` prefix, and the app
reports the resulting 404 as "That code did not match an open study"
([task 0004](../../tasks/backlog/0004-distinguish-missing-route-from-refusal.md)).

Join both phones with `EPIGAME-DEBUG`. Both should show the waiting screen with a countdown, which
is the confirmation that enrolment worked and the schedule was read.

## 3. Let it collect before you tick anything

**Wait until at least two rounds have passed** — ten minutes after `starts_at` — with both phones
near each other and unlocked. This is the step that gets skipped, and skipping it is what makes a
run look broken.

You are waiting for two independent things:

1. **Contact episodes.** Nothing is emitted until an encounter ends, hits 900 s, or goes idle —
   and it must clear `min_duration_seconds: 60` and `min_sample_count: 3` to be uploaded at all.
2. **Coverage.** The first `module_status` arrives 60 s after collection starts. Without it the
   round is scored `not_sensing` no matter how good the proximity data is.

Confirm both before going further:

```sh
psql epidemica_server_dev -c "
SELECT module, schema_uri, count(*), min(received_at), max(received_at)
FROM observations WHERE study_id = '$STUDY' GROUP BY 1,2;"
```

You want **two** rows — `contact_episode` and `module_status` — with counts on both. If
`module_status` is missing, health reporting never started. If `contact_episode` is missing, the
phones are not seeing each other; check the same-study service UUID, Bluetooth, and that the app is
foregrounded.

Then check that both phones see each other, not just one:

```sh
psql epidemica_server_dev -c "
SELECT subject, peer, round(duration_s) AS secs, sample_count
FROM contacts WHERE study_id = '$STUDY' ORDER BY started_at;"
```

Two subjects each reporting the other is what reconciliation needs. One-sided is kept and flagged,
but it means one phone is not being heard.

## 4. Run the rounds

```sh
cd server && mix epidemica.tick --study $STUDY --catch-up
```

`--catch-up` runs every round that has **finished** and stops. It will not run the round in
progress; that is [`ensure_elapsed`](../../server/lib/epidemica_server/twin.ex) refusing to settle a
window whose data has not finished arriving. Expected output:

```
day 1:
  twin      ok
  settle    ok
day 2:
  twin      ok
  settle    ok
```

`refused, that day has not finished yet` on the last round is **correct** — wait for the clock.

Re-run it every few minutes, or leave it running:

```sh
watch -n 60 "mix epidemica.tick --study $STUDY --catch-up"
```

This is deliberately manual. An automatic scheduler
([task 0002](../../tasks/backlog/0002-scheduled-ticks.md)) would fire immutable ticks while you are
mid-inspection, which is the opposite of what debugging needs.

## 5. Check what the round decided

```sh
psql epidemica_server_dev -c "
SELECT day, period_start, period_end,
       jsonb_array_length(inputs->'contacts') AS edges,
       outputs->>'newly_infected' AS new_cases,
       outputs->>'total_cases'    AS total
FROM twin_ticks WHERE study_id = '$STUDY' ORDER BY day;"
```

`edges: 0` on a round where you know the phones were together means the observations had not
arrived before the tick's cutoff. Check `received_at` against `period_end`.

Then the scoring:

```sh
psql epidemica_server_dev -c "
SELECT day, subject, closing, settlement->'lines' AS lines
FROM game_ledger WHERE study_id = '$STUDY' ORDER BY day, subject;"
```

`[{\"points\": 0, \"reason\": \"not_sensing\"}]` means coverage fell below 0.5 for that round — go
back to step 3.

## 6. Exercise the app

With rounds now landing every five minutes:

- **State display.** Colour and label change with `epi_state`. Pull to refresh; the app also polls
  every 60 s.
- **The settlement card.** Every line should be explicable from the ledger row above.
- **Protection.** Tap *Protect me*. Confirm a row in `game_actions`, then that the next round shows
  a `-1` protection line and no contact points. It lasts one round.
- **The one-round lag.** Get infected and confirm you still earned that round's `healthy` points —
  scoring uses the state you were *shown*, so nobody is docked retroactively.
- **Forced protection.** Turn Bluetooth off on one phone for a full round. It should show
  "Protected because your phone is not sensing" with the button disabled, and score 0.
- **Finishing.** After round 7 the app shows GAME OVER and a final score, and the protect button
  disappears.

### The surveys

Two cards appear above the score, on **two different clocks**.

**About you** — four demographic questions — is anchored to *enrollment*, at an offset of zero. It
appears as soon as you join, whenever that is. Join half an hour late and you still get it, because
it asks about you, not about the study.

**A quick check-in** — three questions — is anchored to the *study*, sixty seconds into the second
round, so 360 seconds after `starts_at`. Join after its 30-minute window has closed and you never
see it, which is correct: it asks about a period you were not there for.

That contrast is the thing to check. Anchoring a demographics instrument to the study is the failure
the anchor exists to prevent — under rolling enrolment it silently asks nothing of every late
joiner, and the hole in the data looks exactly like refusal. **Join one phone late on purpose** and
confirm it is offered *About you* and not *A quick check-in*.

Both are offered rather than forced — an instrument a participant cannot get past is abandoned along
with everything after it.

Worth checking:

- Answering and sending records one observation. It should reach the server `validated: true`,
  because the response is checked against
  [`observations/instruments/survey_response`](../../contracts/observations/instruments/survey_response/1.0.0.json).
- **Not now** leaves the card in place. Backing out is not an answer, and recording a refusal the
  participant did not give would invent a decision.
- **Rather not say** on an optional item records `refused`, which is a different measurement from
  never reaching it.
- **Finish later — send what I have** records the rest as `not_reached` and marks the response
  `partial: true`. Attrition within an instrument is itself a measurement.
- Once sent, a card does not come back, and it does not come back after a restart either.
- Each window is 30 minutes. After that the card disappears whether or not it was answered.

```sh
psql epidemica_server_dev -c "
SELECT subject, payload->>'instrument_id' AS instrument, validated,
       payload->>'partial' AS partial,
       jsonb_array_length(payload->'answers') AS answers
FROM observations WHERE module = 'survey';"
```

## 7. Replay

This is the point of the exercise. To run the whole arc again against the **same real contact
data**:

```sh
mix epidemica.reset_study --study $STUDY
mix epidemica.tick --study $STUDY --catch-up
```

That clears ticks, agents, ledger, awards and published state. It **keeps** every observation and
every protection decision, because both are things that happened rather than things the study
concluded — a replay that dropped them would score a different game from the one that was played.
Add `--clear-actions` when the point is to exercise the protect flow again from nothing.

The seed is derived from `{study_id, day}`, so **a replay with unchanged parameters produces
identical results.** Any difference is caused by something you changed or by observations that
arrived in between — which makes this a real experiment rather than a re-roll.

To change a *parameter*, edit the bundle and re-seed. That creates a **new study** with a new id
(the hash changes), so the phones must re-join and collected data does not carry over. Plan
parameter sweeps accordingly: change one thing, then collect again.

## 8. Look at the network the model actually saw

A settled run answers *what* happened; the network says *why*. This is also the quickest way to
notice that something is wrong — an isolated participant, an epidemic that never reaches anyone
real, a day with no edges at all.

**Export the ticks.** These are the edges the tick was run against, read back from
`twin_ticks.inputs`, not a fresh query of the observation store. A picture built from anything else
would show a study that never happened.

```sh
cd server
mix epidemica.export_network --study $STUDY --out ../analysis/netviz/network.json
```

**Add the simulated mixing.** The engine draws virtual contacts inside each tick from its seed and
does not store them, so the export has only the measured ones. This rebuilds them by calling the
same function the tick called, with the same seed:

```sh
cd ../models
uv run python -m starsim_epidemica.netviz ../analysis/netviz/network.json
```

Expect the second number to dwarf the first — a seven-round debug study exports around 15 measured
edges and 2 300 virtual ones. **Skip this step and the epidemic appears to spread with nothing
touching anybody**, because at these settings the simulated population supplies most of a real
participant's exposure.

**Open it.**

```sh
cd ../analysis/netviz && python3 -m http.server 8000
```

Then visit `http://localhost:8000`. Opening `index.html` straight from disk also works — the
browser refuses to read a sibling file, so use the file picker it offers instead.

### Reading it

Participants sit in the middle with the first four characters of their pseudonym; the simulated
population rings them, drawn smaller and shaded back so their state stays readable without being
mistaken for a measurement. Colours match the app: green healthy, red infected, blue recovered. A
**gold ring** marks someone infected on that day, which is the thing to follow as you scrub.

Bold indigo lines are measured contacts, thickness by dose weight. Faint grey lines are simulated
contacts, and by default only those *reaching a participant* are drawn — the exposure the study
cannot see but the model acted on. **show every simulated contact** reveals all of them, which is a
hairball, but it is the honest picture of how much of the network is modelled rather than observed.

Things worth checking on a good run:

- Participants who were together should share a bold line on the rounds they were together.
- A participant turning red should have an infectious neighbour on the round before.
- The ring should turn red faster than the centre. If it does not, `virtual.contacts_per_day` or
  `beta` is too low for the game to work.
- A round with **0 contacts shown** and no measured edges is the signature of the episode-length
  interaction described above, not of a phone that failed.

## 9. When it all works

Run `epigame7` unchanged for a real multi-day test. What the compressed run cannot tell you is
whether the app survives being backgrounded overnight, whether iOS keeps sensing for 24 hours, and
whether the first-hour coverage gap matters in practice. Those need real days.

---

## Troubleshooting

| Symptom | Most likely cause |
|---|---|
| "That code did not match an open study" | Missing trailing slash on `EPIDEMICA_SERVER` ([0004](../../tasks/backlog/0004-distinguish-missing-route-from-refusal.md)) |
| `The join code ... already belongs to study` | Correct, and it saved you. Re-run with `STEAL_CODE=1` |
| No countdown screen, or the game looks already started | The phone joined an earlier study whose start has passed. Check `SELECT j.code, s.protocol->'schedule'->>'starts_at' FROM join_codes j JOIN studies s ON s.id = j.study_id;` |
| `no study <uuid>` from the tick task | Used the bundle's `study_id` instead of the server's ([0005](../../tasks/backlog/0005-bundle-study-id-is-not-the-study-id.md)) |
| Everyone `not_sensing` | No `module_status` yet, or `health.interval_seconds` too long for the tick |
| `refused, that day has not finished yet` | Correct. Wait, or `--force` for a demo |
| `edges: 0` with data in the DB | Observations arrived after the tick's `received_before` |
| Only one subject in `contacts` | One phone is not being discovered; check Bluetooth and foreground |
| App shows nothing after joining | No round has been ticked yet. State is never synthesised |
| Nothing uploads with the app swiped away | Known on Android: sensing continues but no Dart runs, so nothing drains the outbox ([0006](../../tasks/backlog/0006-no-background-sync.md)) |

## See also

- [`docs/concepts/epigame.md`](../../docs/concepts/epigame.md) — how the whole pipeline fits together
- [`docs/debugging.md`](../../docs/debugging.md) — VS Code launch configurations
- [`studies/epigame7`](../epigame7) — the real study this compresses
