# studies/epigame7

The M2 study: a seven-day game about how an infection moves through a group.

**This directory contains no code, and that is the point.** It is a single
[`bundle.json`](bundle.json) validated against
[`contracts/bundle/1.0.0.json`](../../contracts/bundle/1.0.0.json). The app that runs it,
[`apps/epigames`](../../apps/epigames), contains no epidemiology and no economics: both are in this
file, so a second game with different rules needs a new bundle rather than a new build.

## What makes this different from `contactlog`

Three blocks that a collection-only study does not have.

**`schedule`** gives the study a start and an end. Day 1 begins at `starts_at` and there is no day
after `days`. Without it the first day would be anchored to whenever the study happened to be
registered, so re-registering would silently move every boundary and a participant's "day 3" would
mean nothing. The instant is absolute rather than a local date, so a study spanning a
daylight-saving change keeps its days a fixed length.

**`twin`** says a model runs against this study's data and where its output is contracted. The
population is 60 against a much smaller enrolment: the remainder are simulated participants, whose
presence the app's information screen discloses. Without them a class-sized group would rarely
produce an outbreak at all, and there would be no game.

`twin.seed` starts the outbreak. Without it the study runs its full seven days, settles every
score, and simulates nothing — which on a participant's screen is indistinguishable from a disease
that failed to spread. Three cases are seeded `among: "virtual"`, so the lottery never falls on a
real player: being infected on day one costs most of the game, for a reason the participant can
neither see nor influence. It also means every real infection has a contact behind it rather than
an unexplainable start. A study that wants a player as its index case sets `among: "participants"`
deliberately.

**`rules`** holds every number the score uses. Nothing about the economics is compiled into the
app or the server.

## Why the settings are what they are

`min_duration_seconds: 60` and `min_sample_count: 3` discard the briefest encounters. `contactlog`
keeps everything because its purpose is to check the pipeline; here a passing glance in a corridor
should not earn points or drive transmission.

`beta: 0.35` with `dur_inf_days: 5` is tuned so that a seven-day game usually produces a visible
outbreak without infecting everyone by day three. It is a game parameter, not an estimate of any
real pathogen, and the study should not be read as claiming otherwise.

`virtual.contacts_per_day: 6` gives the simulated population enough mixing to sustain an epidemic
between themselves and to reach the real participants. Set it to zero and the virtual agents become
inert, which is a useful thing to try once: the game stops working, visibly.

`protection.blocks_transmission: true` makes protection altruistic as well as selfish — a protected
participant neither catches nor passes on. That is the property the game is teaching, and the
information screen says so plainly.

`contact_points_while_infected: false` means an infected player earns nothing for contacts. The
alternative pays an infectious player to seek company, which is the opposite of the lesson.

## Running it

See [`deploy/epigames`](../../deploy/epigames). The start date committed here is a placeholder;
`START=` or `TODAY=1` sets a real one at registration time.
