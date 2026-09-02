# Running a study locally

Everything needed for the M1 acceptance run: five devices in one room for one hour, producing a
contact network in Postgres.

```sh
deploy/contactlog/up.sh
```

That starts PostgreSQL if it is not already running, migrates, registers
[`studies/contactlog`](../../studies/contactlog), prints a join code, and serves on this machine's
LAN address. Then, in another terminal:

```sh
cd apps/template
flutter run --dart-define=EPIDEMICA_SERVER=http://<your-lan-ip>:4000/v1/
```

`up.sh` prints the exact command with the address filled in.

## The one thing that catches people out

Phones cannot reach `localhost`. The server hands the app an absolute `protocol_url` pointing at
itself, and the app fetches that URL directly — so if the server advertises `localhost`, enrolment
succeeds, the bundle fetch fails, and the app refuses the study without the server ever logging an
error. `up.sh` works out this machine's LAN address from the routing table and binds to every
interface to avoid exactly that.

Every phone must be on the same network. Guest wifi with client isolation will not work.

## Registering a different study

```sh
cd server
mix epidemica.seed_study --bundle ../studies/contactlog/bundle.json --code PILOT-2026
```

The bundle's bytes are stored verbatim and its hash derived from them, so the hash always describes
exactly what will be served. Re-running with the same file adds another join code rather than a
second copy of the study.

This is also how the "same binary, different study" claim is checked in the field: register a second
bundle naming different modules, join with its code, and the app collects something else without a
rebuild.

## Checking the run

Pending observations on each phone are shown on the app's status screen; they should fall to zero
within a few minutes of a sync.

Server-side:

```sh
cd server
mix run -e '
  import Ecto.Query
  alias EpidemicaServer.{Repo, Ingest.Observation}
  IO.inspect(Repo.aggregate(Observation, :count), label: "observations")
  IO.inspect(Repo.all(from o in Observation, group_by: o.device_id,
    select: {o.device_id, count(o.id)}), label: "per device")
'
```

Five devices in a room should produce contacts in both directions for each pair — an asymmetry
where A sees B but B never sees A usually means one phone's Bluetooth permission was declined, or
its screen stayed locked past the point where the foreground service should have taken over.

## Closing the loop

The milestone is not met by data arriving; it is met by that data being usable. Export and run it
through the analysis and model paths:

```sh
cd analysis && uv run pytest -q     # contract validation
cd ../models  && uv run pytest -q   # the Starsim bridge the network has to load into
```

If the measured network cannot drive a simulation, something upstream is wrong in a way no unit test
will reveal — which is why that second step is part of the acceptance criteria rather than a
nice-to-have.

## Stopping

`Ctrl-C` twice stops the server. PostgreSQL keeps running as a background service; stop it with:

```sh
brew services stop postgresql@14
```
