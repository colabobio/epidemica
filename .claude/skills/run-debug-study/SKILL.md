---
name: run-debug-study
description: Exercise the Epigames pipeline end to end using the compressed epigame-debug study — enrolment, sensing, ticks, settlement, scoring and publication in one sitting. Use when field-testing the app, reproducing a reported study bug, or verifying a change to the twin, scoring or state channel.
---

# Run the debug study

`studies/epigame-debug/` compresses the seven-day game into about 35 minutes: 300-second rounds,
60-second health reporting, everything else identical to `epigame7`. It is a debugging instrument —
nothing it produces is an epidemiological result.

Full procedure, with the reasoning for each setting:
[`studies/epigame-debug/README.md`](../../../studies/epigame-debug/README.md). This skill is the
short form plus the places people go wrong.

## Sequence

```sh
# 1. Start ten minutes in the future so phones are collecting before round 1
START="$(date -u -v+10M +%Y-%m-%dT%H:%M:%SZ)" \
  BUNDLE=studies/epigame-debug/bundle.json \
  deploy/local/epigames/up.sh

export STUDY=<the "Created study" id it prints>

# 2. Both phones — trailing slash required
cd apps/epigames && flutter run --dart-define=EPIDEMICA_SERVER=http://<lan-ip>:4000/v1/

# 3. Wait two full rounds with both phones near each other, unlocked

# 4. Run finished rounds
cd server && mix epidemica.tick --study $STUDY --catch-up

# Replay from the same observations as often as you like
mix epidemica.reset_study --study $STUDY
```

## The four mistakes

**Ticking before data has accumulated.** Step 3 is the one that gets skipped, and skipping it is
what makes a healthy run look broken. Confirm *both* observation types exist before any tick:

```sh
psql epidemica_server_dev -c "
SELECT module, schema_uri, count(*) FROM observations WHERE study_id = '$STUDY' GROUP BY 1,2;"
```

Two rows — `contact_episode` and `module_status`. No `module_status` means every round will score
`not_sensing` regardless of how good the proximity data is.

**Using the bundle's `study_id`.** The server generates its own. Use the id printed by `up.sh`
([task 0005](../../../tasks/backlog/0005-bundle-study-id-is-not-the-study-id.md)).

**Omitting the trailing slash on `EPIDEMICA_SERVER`.** `Uri.resolve` drops `/v1`, and the app
reports the 404 as "That code did not match an open study".

**Using `TODAY=1`.** It anchors to the top of the current hour; a 35-minute study is usually over
before you have installed anything.

## Expected refusals

`refused, that day has not finished yet` on the final round is **correct** — `ensure_elapsed`
declining to settle a window whose data is still arriving. Wait for the clock rather than reaching
for `--force`.

Ticking is deliberately manual. A scheduler would fire immutable ticks while you are mid-inspection.

## Recovery

A wrong tick is permanent — `twin_ticks` is unique on `(study_id, day)`. `mix epidemica.reset_study
--study $STUDY` clears the derived state and **keeps `game_actions`**, because participant choices
are input, not output; discarding them makes the replay a different experiment. Observations are
kept too, so you can collect real contact data once with real phones and replay the game against it
repeatedly.

## If a shortened tick is involved

`health.interval_seconds` must stay well below `twin.tick_interval_seconds` — a fifth here. Coverage
is a fraction of the tick period, so a long health interval means the first report arrives after
every round has already closed, and every participant reads `not_sensing` with no error anywhere.
