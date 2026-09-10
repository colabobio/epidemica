# Running the Epigames seven-day study, end to end

Everything in order, from nothing to a study advancing on its own. This is the document to follow
for the first real cohort. It draws on [`aws/README.md`](aws/README.md) and
[`app-release/README.md`](app-release/README.md) rather than repeating them, and adds the ordering
and the checks that only matter when the two are combined.

**Before you start:**

- An AWS account, a region, and **a DNS name you control**. Decide the name first: it is baked into
  `PHX_HOST`, which the server puts inside every `protocol_url` it hands a phone. Changing it after
  devices have enrolled is not a redeploy, it is a new study.
- A macOS or Linux machine with the repository checked out, Flutter installed, and Docker running.
- Apple Developer and Google Play accounts only if the apps are going to the stores. For a first
  cohort, a debug APK shared directly is fine and much faster to iterate.

## 1. Stand up the server

Follow [`aws/README.md`](aws/README.md) sections 1–3. Three things there are load-bearing, in
order of how hard they are to diagnose if you skip them:

1. **`PHX_HOST` must be the public name exactly as the app will reach it.** If the app reaches the
   server by one name and is told to fetch its protocol from another, enrolment *succeeds* and the
   bundle fetch fails, with nothing logged server-side. This is the most common way a deployment
   appears to work and does not.
2. **Run the twin smoke test.** The server builds, starts, and serves enrolment perfectly well
   without a working Python environment — then fails every tick with `{:engine_unavailable, _}`,
   which on a participant's phone is a study where nothing ever happens.
3. **HTTPS.** Android blocks cleartext from API 28 and iOS blocks it under ATS. `http://` works on
   a LAN in debug and nowhere else.

## 2. Register the study

Section 4 of the AWS guide, in full. The two things to get right, neither of which will tell you if
you got them wrong:

- **`starts_at` is an absolute instant, not a local date.** Pick the instant corresponding to local
  midnight where the cohort is, and check whether daylight saving changes during the seven days. A
  wrong instant is not an error; it is a study whose days do not line up with anybody's.
- **The join code is what participants type.** `EPIGAME-7` is the committed placeholder. A 404 on an
  unknown code is deliberately indistinguishable from a closed study, so a typo in the code you
  circulate looks to participants exactly like a server that is down.

Write down the study id it prints. Everything below needs it.

## 3. Build the apps

```sh
cd apps/epigames
flutter build apk --dart-define=EPIDEMICA_SERVER=https://study.example.org/v1/
```

**The trailing `/v1/` is required.** Without it the app resolves `enrollments` against the host root,
gets a 404, and reports it as "unknown join code" — a network misconfiguration that looks to the
participant like the study does not exist.

Build this *after* step 2, so you can enrol one device against the real study before touching the
cohort. For a store build, the command is the same and the signing config comes from
[`app-release/README.md`](app-release/README.md). Do not ship debug-signed.

## 4. Verify the scheduler before anyone installs anything

The study advances on its own. Confirm the machinery that advances it exists *before* the cohort
arrives, because the failure mode is silence:

```sh
docker compose exec -T server /app/bin/epidemica_server eval \
  'EpidemicaServer.Ops.status("<study-id>")'
```

Before the start date this should report the study as open with nothing ticked and nothing due.
That is the correct answer, and it also proves `Ops` is reachable in the release.

Then confirm the cron plugin itself is alive — a study that is simply quiet looks identical to a
scheduler that has never run:

```sh
docker compose exec -T server /app/bin/epidemica_server eval '
  import Ecto.Query
  EpidemicaServer.Repo.all(
    from j in Oban.Job,
      where: j.worker == "EpidemicaServer.Twin.Scheduler",
      order_by: [desc: j.inserted_at],
      limit: 5,
      select: {j.state, j.inserted_at}
  ) |> IO.inspect(label: "scheduler runs")
'
```

Empty output within the first hour is expected; empty output after two hours means the plugin is not
running. Check the image was built after the cron entry was added, and that it is running as
`:prod` — the cron entry is deliberately absent in dev and test.

## 5. Enrol one device yourself

Before the cohort. Install the APK, join with the real code, and confirm:

- The enrolment screen shows the study's **title and start date from the bundle**. Blank, or a
  network error, means `PHX_HOST` and the app's `EPIDEMICA_SERVER` disagree — step 1, item 1.
- The proximity permission flow completes and the app reports it is sensing.

Then check the server saw it:

```sh
docker compose exec -T server /app/bin/epidemica_server eval '
  import Ecto.Query
  EpidemicaServer.Repo.aggregate(
    from(p in EpidemicaServer.Enrollment.Participant,
      where: p.study_id == type("<study-id>", :binary_id)), :count
  ) |> IO.inspect(label: "participants")
'
```

## 6. Recruit

Circulate the join code. Nothing else is required of an operator to start the study — the schedule
is in the bundle, and the first day begins at `starts_at` whether or not anyone is watching.

Participants who join late are enrolled from that moment. They are scored from the day they joined;
earlier days are not backfilled and are not held against them.

## 7. During the run

Nothing is required daily. The scheduler runs hourly, offers each day once its period **plus its
buffer** has passed, and `Twin.Worker` runs the tick and enqueues settlement.

The one command worth running once a day:

```sh
docker compose exec -T server /app/bin/epidemica_server eval \
  'EpidemicaServer.Ops.status("<study-id>")'
```

Read it carefully — `behind` and `due now` are different questions. A day that is over but inside
its buffer is behind and not yet due, and that is correct, not a fault.

If days are genuinely stuck, force them rather than waiting:

```sh
docker compose exec -T server /app/bin/epidemica_server eval \
  'EpidemicaServer.Ops.catch_up("<study-id>")'
```

### Telling a scheduler problem from a sync problem

These look similar from a distance and have nothing to do with each other.

**A day that has not ticked** when it should have is a scheduler problem. Check the Oban query in
step 4 first.

**A day that ticked but scored most participants `not_sensing`** is a sync problem — the tick ran,
the data had not arrived. Count it:

```sh
docker compose exec -T server /app/bin/epidemica_server eval '
  import Ecto.Query
  EpidemicaServer.Repo.all(
    from l in EpidemicaServer.Epigame.LedgerEntry,
      where: l.study_id == type("<study-id>", :binary_id),
      select: {l.day, fragment("?->>?", l.settlement, "lines")}
  )
  |> Enum.map(fn {day, lines} -> {day, Jason.decode!(lines) |> Enum.map(& &1["reason"])} end)
  |> Enum.flat_map(fn {day, reasons} -> Enum.map(reasons, &{day, &1}) end)
  |> Enum.frequencies()
  |> IO.inspect(label: "reasons by day")
'
```

`reason` is inside the settlement document, not a column: the ledger stores what was decided, whole,
so a settlement can be re-read exactly as the participant saw it. That is why this query is uglier
than it looks like it should be.

Widespread `not_sensing` on day 1 usually means phones are collecting but not uploading. Check the
device-side first, not the server.

## 8. What this has not been proven to do

The overnight two-phone test from [`tasks/backlog/0006`](../tasks/backlog/0006-no-background-sync.md)
— whether iOS background wakes deliver enough upload opportunities in practice — **has not been run
on physical hardware.** The scheduler is tested and the sync mechanism is tested; whether the
combination is sufficient for a real cohort is precisely what a first run finds out.

That is not a reason to delay. It is a reason to read section 7's numbers on the morning after day 1
expecting some participants to be `not_sensing` for reasons this codebase cannot yet tell apart —
and to write down what you find rather than assume it is working.

## See also

- [`aws/README.md`](aws/README.md) — the server, in detail
- [`app-release/README.md`](app-release/README.md) — signed builds
- [`studies/epigame-debug`](../studies/epigame-debug/README.md) — the same arc in half an hour,
  which is the right place to make your mistakes first
- [`tasks/done/0002`](../tasks/done/0002-scheduled-ticks.md) — how scheduling decides what is due
