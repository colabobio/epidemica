# studies/epigame-debug-rct

The seven-day game with two-arms random assignment of participants, compressed into about 10 minutes.

Same rules and same disease as [`epigame-debug`](../epigme-debug).

## Why this exists

Needed to test participant randomization between study arms.

---

# Step-by-step: debugging Epigames

Two phones, about 15 minutes. Read the whole sequence before starting — step 3 is the one people
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
  BUNDLE=studies/epigame-debug-rct/bundle.json \
  deploy/local/epigames/up.sh
```

On GNU coreutils use `date -u -d '+10 minutes' +%Y-%m-%dT%H:%M:%SZ`.

Do **not** use `TODAY=1` here. It anchors to the top of the current hour, and a 35-minute study
started at the top of the hour is usually over before you have installed anything.

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
is the confirmation that enrollment worked and the schedule was read.

## 3. Let it collect before you tick anything

**Wait until at least two rounds have passed** — ten minutes after `starts_at` — with both phones
near each other and unlocked. This is the step that gets skipped, and skipping it is what makes a
run look broken.

Participants should have been assigned to two different arms, confirm before going further:

```sh
psql epidemica_server_dev -c "
SELECT arm, count(*) FROM participants WHERE study_id = '$STUDY' 
GROUP BY arm ORDER BY arm;"
```

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

## 5. Visualize the network

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
