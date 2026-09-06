# Running the Epigames seven-day study, end to end

Everything in one place, in order, from a fresh machine to a study that is advancing on its own.
This is the document to follow for the first real cohort; the AWS and app-release pages it draws
from are [`aws/README.md`](aws/README.md) and [`app-release/README.md`](app-release/README.md).

**What you need before starting:**

- An AWS account, a region (use `us-east-1` or `us-west-2` unless there is a reason not to), and a
  DNS name you control — decide the name before you build anything, because it is baked into
  `PHX_HOST` and therefore into every `protocol_url` the app will ever fetch.
- A macOS or Linux machine with the repository checked out and Docker Desktop running, for building
  the apps.
- An Apple Developer account and a Google Play Console account if either app is going to real
  stores. Debug builds on real phones are fine for the first test; signed store builds are not.

## 1. Build the apps

```sh
cd apps/epigames
flutter build apk --dart-define=EPIDEMICA_SERVER=https://study.epidemica.info/v1/
```

Two rules, both load-bearing:

- **`https://`, not `http://`.** Android blocks cleartext from API 28 and iOS ATS blocks it. A
  debug build on a LAN is the only place `http://` ever works.
- **The trailing `/v1/` is required.** Without it the app resolves `enrollments` against the host
  root and gets a 404 it reports as "unknown join code" — a failure that looks like the study does
  not exist.

For the first test with a recruited cohort, a debug APK shared directly (not through the Play store)
is fine and faster to iterate. A store build is the same command with `--dart-define` unchanged and
the signing config from [`app-release/README.md`](app-release/README.md) filled in — do not
ship debug-signed.

## 2. Stand up the server

Follow [`aws/README.md`](aws/README.md) sections 1–4 exactly. The parts that matter most, in
order of how hard they are to debug if you skip them:

1. **Decide the DNS name first.** It is baked into `PHX_HOST`, which the server puts inside every
   `protocol_url` it hands to a phone. Changing it after devices have enrolled means they can no
   longer fetch their protocol — not a redeploy, a new study.
2. **`PHX_HOST` must be the public DNS name exactly as the app was built to reach it.** If the app
   reaches the server by one name and is told to fetch its protocol from another, enrolment succeeds
   and the bundle fetch fails with nothing logged server-side. This is the single most common way a
   deployment appears to work and does not.
3. **The twin smoke test is not optional.** The server builds, starts, and serves enrolment without
   Python — and then fails every tick with `{:engine_unavailable, ...}`, which on a participant's
   phone looks like a study where nothing ever happens. Run the smoke test in section 3 of
   `../aws/README.md` before registering anything.

## 3. Register the study

```sh
docker compose cp ../../studies/epigame7/bundle.json server:/tmp/bundle.json

docker compose exec server /app/bin/epidemica_server eval '
  bundle = File.read!("/tmp/bundle.json") |> Jason.decode!()
  bundle = put_in(bundle["schedule"]["starts_at"], "2026-09-14T04:00:00Z")
  source = Jason.encode!(bundle)
  {:ok, study} = EpidemicaServer.Studies.create_study_from_bundle("Epigame seven-day", source)
  {:ok, _} = EpidemicaServer.Studies.add_join_code(study, "EPIGAME-7")
  IO.puts("study #{study.id} code EPIGAME-7")
'
```

Two things to get right here, neither of which will tell you if you got them wrong:

- **`starts_at` is an absolute instant, not a local date.** `2026-09-14T04:00:00Z` is midnight in
  New York on daylight time. Pick the instant that corresponds to local midnight where the study
  runs, and check whether daylight saving changes during the study's run. A wrong instant is not an
  error; it is a study whose days do not line up with calendar days.
- **The join code is what participants type.** `EPIGAME-7` is a placeholder; choose something
  unambiguous for the cohort, and note that a 404 on an unknown code is deliberately
  indistinguishable from a closed or full study — the server does not confirm whether a code exists.

## 4. Verify the scheduler before anyone installs anything

The study advances on its own once it starts. Before the cohort installs, confirm the machinery
that advances it is actually there:

```sh
# The scheduler is running and finding nothing due yet — which is the correct answer before
# anyone has enrolled. Both of these should return quickly and say so.
docker compose exec server /app/bin/epidemica_server eval '
  EpidemicaServer.Twin.Scheduler.due_ticks() |> IO.inspect(label: "due")
'

docker compose exec server /app/bin/epidemica_server eval '
  EpidemicaServer.Repo.all(
    from j in Oban.Job, where: j.worker == "EpidemicaServer.Twin.Scheduler",
    order_by: [desc: j.inserted_at], limit: 3
  ) |> Enum.map(&{&1.state, &1.inserted_at}) |> IO.inspect(label: "scheduler runs")
'
```

If the second command returns nothing, the Cron plugin is not running — check that `config.exs` in
the running image contains the `Oban.Plugins.Cron` entry, and that the image was rebuilt since it
was added. A study that should have ticked and has not is a study whose scheduler is not running;
this is the check that tells you before the cohort does.

## 5. Install and enrol

Each participant installs the APK from step 1, opens it, and types the join code from step 3. The
enrolment screen is the one place to confirm the two things that can silently go wrong:

- The app shows the study's title and start date from the bundle. If it shows nothing, or shows a
  network error, `PHX_HOST` and the app's `EPIDEMICA_SERVER` do not agree — see step 2, item 2.
- The join code is accepted on the first try for one participant before the cohort types it in
  bulk. A typo'd code is indistinguishable from a server problem from the participant's side.

## 6. During the study

Nothing is required of an operator during a run. The scheduler runs hourly, enqueues each day once
its period plus buffer has passed, and `Twin.Worker` runs the tick and enqueues settlement. The
things worth checking once a day, not as a routine but as a sanity check after anything looks off:

```sh
# Which days have actually ticked so far
docker compose exec server /app/bin/epidemica_server eval '
  EpidemicaServer.Repo.all(
    from t in EpidemicaServer.Twin.Tick, where: t.study_id == ^"<study-id>", order_by: t.day
  ) |> Enum.map(&{&1.day, &1.ran_at}) |> IO.inspect(label: "ticked")
'

# Whether any participants are being scored not_sensing more than expected — the sign that
# background sync is not reaching enough of them
docker compose exec server /app/bin/epidemica_server eval '
  EpidemicaServer.Repo.all(
    from l in EpidemicaServer.Epigame.LedgerEntry,
    where: l.study_id == ^"<study-id>",
    group_by: l.reason, select: {l.reason, count(l.id)}
  ) |> IO.inspect(label: "by reason")
'
```

A day that has not ticked when it should have is a scheduler problem; check section 4's commands
first. A day that ticked with mostly `not_sensing` is a sync problem, not a scheduler problem —
check that participants' phones are actually uploading before concluding the scheduler is at fault.

## 7. Running alongside the open-ended demo

The seven-day study and the open-ended demo can run on the same server, and they do not conflict.
Each study's days are derived from its own bundle's `starts_at` and `tick_interval_seconds`, and the
scheduler checks each open study independently — a day due for one is a day due for one, not a day
that somehow belongs to both. `Twin.Worker`'s idempotency (a day already run returns
`already_run` and is treated as success) is the guarantee that running both at once is safe, not a
courtesy.

Register the demo the same way, with its own join code:

```sh
docker compose cp ../../studies/epigame-demo/bundle.json server:/tmp/demo-bundle.json

docker compose exec server /app/bin/epidemica_server eval '
  bundle = File.read!("/tmp/demo-bundle.json") |> Jason.decode!()
  bundle = put_in(bundle["schedule"]["starts_at"], "2026-09-08T04:00:00Z")
  source = Jason.encode!(bundle)
  {:ok, study} = EpidemicaServer.Studies.create_study_from_bundle("Epigame demo", source)
  {:ok, _} = EpidemicaServer.Studies.add_join_code(study, "EPIGAME-DEMO")
  IO.puts("demo study #{study.id} code EPIGAME-DEMO")
'
```

One thing to know: the demo's `tick_interval_seconds` is the same as the seven-day game's (a day),
so both tick on the same daily boundary, just offset by their own `starts_at`. They do not need to
line up, and they do not need to not line up — they are simply two studies answering two different
questions at two different cadences on the same server.

## 8. What is deliberately not covered here

The overnight two-phone test from [`tasks/done/0006`](../tasks/done/0006-no-background-sync.md)
— whether iOS background wakes deliver enough upload opportunities in practice — has not been run on
physical hardware, and this document does not claim it has. The scheduler and the sync mechanism are
both in place and both tested; whether they are sufficient for a real cohort is what the first run
exists to find out.

That is not a reason not to run the study. It is a reason to check the day-after numbers in section
6 with the expectation that some participants will be `not_sensing` for reasons this codebase cannot
currently distinguish from each other, and to file what you find rather than assume it is working.
