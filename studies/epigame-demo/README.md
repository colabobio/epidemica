# Epigame: demo

An open-ended Epigame study, for demonstrating the app and for store reviews. There is no last
day; the outbreak runs until the study is shut down. Participants join at any time, play until
they recover or die, and leave when they choose to — or are removed after a grace period if they
finish and go quiet.

## What makes this different from the seven-day game

The mechanics are the same; the shape is not. A seven-day game has a beginning, a middle, and an
end, and every participant knows when it ends. A demo study has no end, so the question it answers
is not "what did the epidemic do" but "what does it look like to be in one."

Two parameters control the shape, both in the bundle's `twin` block:

- **`turnover_after_days`** — how long a virtual agent lives before being retired and replaced by
  a fresh susceptible. Thirty days here, so the population is always renewing rather than slowly
  exhausting itself. Zero would mean virtual agents never retire, which is the right answer for a
  real study and the wrong one for a demo that needs to stay interesting for whoever joins next.
- **`finished_grace_days`** — how long a participant stays in the simulation after reaching a final
  state (recovered or dead). Two days here, so the game ending does not feel like being shut out
  mid-sentence. A participant who finishes and immediately uninstalls is counted differently — see
  *Leaving the game* below.

A participant who finishes is shown "Finished" by the app, using the same rendering as the end of a
seven-day game, because the server tells them the game is over for *them* rather than waiting for a
study-level end that does not exist.

## Leaving the game

Three ways out, and they are not interchangeable:

- **The participant chooses to leave.** The app offers it; the study honours it immediately.
- **They finish and go quiet.** A participant who reaches a final state and stops uploading is
  removed after `finished_grace_days` of silence — the study's way of not keeping a slot for
  someone who uninstalled the app and forgot.
- **They just uninstall the app.** No signal, no update, no upload. A participant whose phone has
  not spoken to the server in `sync.min_interval_seconds` × 4 is treated as gone on the next tick
  after that — the study's way of not keeping a slot for someone who is definitely not coming back.

The third case is the one that matters most for a demo: someone who tries the app for ten minutes
at a store review and uninstalls it is not a participant the study should keep simulating.

## Using it

```sh
cd server
mix epidemica.seed_study --bundle ../studies/epigame-demo/bundle.json --code EPIGAME-DEMO
```

Then run the server normally. The scheduler runs on its own — there is no `days` ceiling, so
`Twin.Scheduler` offers a new day every `tick_interval_seconds` until the study is shut down. Shut
it down by closing the study:

```sh
mix run --no-start -e '
  study = EpidemicaServer.Studies.get_study("<study-id>")
  study |> Ecto.Changeset.change(status: "closed") |> EpidemicaServer.Repo.update!()
'
```

A closed study stops offering new days. Its existing ticks remain in the record, reproducible.

## When the outbreak dies out

It will, eventually. An epidemic that has run its course — every susceptible recovered or dead — is
not a demo anymore, just a contact log with a simulation attached that is simulating nothing. The
scheduler re-seeds it: a tick that finds no active infections in an open-ended study starts a new
outbreak from the same seed the study began with, so the demo keeps running rather than quietly
ending. This is a property of the open-ended study specifically; a finite study's epidemic is
allowed to burn out, because that is the answer to the question it exists to ask.

## What this is not for

A real cohort. The parameters are chosen for a demo: a population of 100 rather than the
epidemiologically-motivated 60 of the seven-day game, a 30-day turnover so the demo stays
interesting, and a 2-day grace period so the demo feels generous rather than abrupt. A study
answering a real research question should start from [`epigame7`](../epigame7) and change the
parameters it actually needs, not from this one.
