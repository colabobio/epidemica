# Running the Epigame locally

The seven-day game: phones in a room for a week, a simulated population making up the numbers, and
a score that a participant can check.

```sh
TODAY=1 deploy/local/epigames/up.sh
```

That starts PostgreSQL, migrates, checks the Starsim environment, registers
[`studies/epigame7`](../../../studies/epigame7) starting at the top of the current hour, prints a join
code, and serves on this machine's LAN address. Then:

```sh
cd apps/epigames
flutter run --dart-define=EPIDEMICA_SERVER=http://<your-lan-ip>:4000/v1/
```

`up.sh` prints the exact command with the address filled in.

## The study has a start and an end

Unlike `contactlog`, this study is scheduled. Day 1 begins at the instant the bundle names, and
there is no day 8 — asking for one is refused rather than quietly extending the study.

That schedule is part of the protocol, so changing it changes the bundle's hash. This is correct:
a study that starts on a different day is a different study, and the hash is what tells the app
the configuration it received is the one the server meant. Rather than edit the committed file
before every run, set the start on the command line:

```sh
START=2026-09-07T06:00:00Z deploy/local/epigames/up.sh   # a specific instant
TODAY=1                    deploy/local/epigames/up.sh   # the top of the current hour
```

Either writes a dated copy of the bundle and registers that, so the bytes served and the hash
derived from them always agree.

`starts_at` is an absolute instant rather than a local date. A study spanning a daylight-saving
change keeps its boundaries a fixed distance apart, and "day 3" means the same interval for
everyone. Pick the instant that corresponds to local midnight where the study runs.

## Advancing a day

The game moves when a tick runs. In a real deployment that is a queued job; for a demonstration or
a test run, do it by hand:

```sh
cd server
mix epidemica.tick --study <study-id> --day 1     # one day
mix epidemica.tick --study <study-id> --catch-up  # every day up to today
```

Each command runs the twin and then settles the score. A day already run is reported and left
alone: participants have been told what happened on it, and running the task twice by accident
must not change their history.

**Nothing is shown to a player until the first tick has run.** That is deliberate. A synthesised
"you are healthy" is indistinguishable on screen from a computed one, and a participant would act
on it.

## Checking a run

```sh
cd server
mix run -e '
  alias EpidemicaServer.{Epigame, Twin}
  study = "<study-id>"
  IO.inspect(Enum.map(Twin.ticks(study), &{&1.day, &1.outputs["total_cases"]}), label: "cases by day")
  IO.inspect(Enum.map(Epigame.ledger(study, "<subject>"), &{&1.day, &1.closing}), label: "balance by day")
'
```

Every tick stores its inputs, its seed and its outputs, so any day can be replayed and checked
rather than trusted:

```sh
mix run -e 'IO.inspect(EpidemicaServer.Twin.verify_tick("<study-id>", 1))'
```

`:ok` means the stored day reproduces exactly. Anything else means the record and the engine
disagree, which is the signal the whole arrangement exists to give.

## What to expect on the phones

Before the study opens, a participant who has joined sees when play starts — codes go out in
advance, and someone who joined in good time should not be left on a blank screen wondering whether
the app is broken. Their phone is already recording; nothing counts yet.

During the game: a solid colour — green healthy, red infected, blue recovered. The points are the
large number; a shield appears when protected. The screen states how old the computation is,
because it is a daily one and an interface that looks live would claim a freshness it does not have.

After the final day's tick, the same screen becomes a result: **GAME OVER**, the final score, and
no protection button — leaving a live one would invite a participant to spend a point on a day that
will never be settled. The server refuses actions outside the study window for the same reason.

If a phone stops sensing — Bluetooth off, app killed, battery flat — that participant is treated as
protected and their day is not scored. They are not charged the protection point either. This is
the rule that keeps a phone in a drawer from being read as somebody who met nobody, and the app
says so on its information screen.

## Querying the database

It can be done from the command line

```sh
psql epidemica_server_dev
```

Once one is in, the following commands are useful:

```sql
\dt              list tables
\d observations  describe a table
\x               toggle expanded output — essential for jsonb payloads
\q               quit
```

A few queries worth having:

```sql
-- who's enrolled
SELECT p.subject, d.platform, p.enrolled_at
FROM participants p JOIN devices d ON d.participant_id = p.id
ORDER BY p.enrolled_at;

-- what's arriving
SELECT module, subject, count(*), max(observed_at) FROM observations
GROUP BY module, subject;

-- one episode in full (\x first)
SELECT subject, payload FROM observations
WHERE module = 'proximity' ORDER BY observed_at DESC LIMIT 1;

-- who saw whom, once episodes exist
SELECT subject, peer, round(sum(duration_s)) AS seconds, count(*) AS episodes
FROM contacts GROUP BY subject, peer ORDER BY seconds DESC;
```

 If you prefer a GUI, point [TablePlus](https://tableplus.com) or [DBeaver](https://dbeaver.io/) at localhost:5432, database epidemica_server_dev, user andres, no password.

## Stopping

`Ctrl-C` twice stops the server. PostgreSQL keeps running as a background service:

```sh
brew services stop postgresql@14
```
