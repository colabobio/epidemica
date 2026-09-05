# 0008 — A survey module: scheduled instruments delivered in the app

**Status:** done
**Filed:** 2026-09-03
**Landed:** 2026-09-05
**Touches:** `contracts/instruments/`, `contracts/observations/instruments/survey_response/1.0.0.json`,
`packages/epidemica_survey/`, `packages/epidemica_core/lib/src/modules/embedded_module.dart`,
`apps/epigames`, `studies/*/bundle.json`

## What was built, and where it differs from this plan

Shipped as **`packages/epidemica_survey`** with module id **`survey`**, not
`epidemica_instruments`/`instruments`. The narrower name says what it actually does; instruments
delivered over SMS or web are a different problem and should not inherit this package's assumptions.

The four open decisions were resolved as follows.

- **Where instrument definitions live** — served separately and versioned independently, as the
  contract already assumed. `contracts/instruments/definition/1.0.0.json` defines them,
  `Instruments.register/2` stores them byte-exact, `GET /instruments/:id/:version` serves them, and
  `HttpInstrumentSource` verifies the digest on the device. The bundle names and pins the versions,
  so a study stays reproducible without its hash changing when a typo is fixed.
- **Who decides it is day 3** — the device, via `SurveySchedule.dueAt`, using the study's own
  interval rather than a hardcoded day. Schedules anchor to either the study start or the
  participant's enrolment, which the server-side option could not express per-participant.
- **What a survey module reports as its status** — `ModuleState` was *not* extended. The module
  reports `stopped` with a `detail` of `'every instrument is done'`. A new state would have been a
  `module_status` contract change to describe something no coverage calculation reads.
- **How the participant finds out** — deferred. See below.

## What was deliberately left undone

1. **Notification delivery.** Without it a survey is seen only when the participant next opens the
   app. [ADR-0015](../../docs/adr/0015-local-notifications-for-scheduled-instruments.md) is
   *Proposed*, and the implementation is filed as
   [task 0010](../backlog/0010-local-notifications.md). This is the one gap that matters for a
   real study.
2. **A survey block in `studies/epigame7`.** Only `studies/epigame-debug` carries one. That is a
   bundle edit, not code, and it should be written with the actual research questions rather than
   placeholders.

## Verification

27 tests in `packages/epidemica_survey`, plus contract tests for the instrument definition with the
usual fixture rules. Exercised end to end on `studies/epigame-debug`, where the scheduled check-in
appears and arrives server-side `validated: true`.

---

*Everything below is the original task as filed, kept for the reasoning.*

## What is wanted

Surveys delivered by the app at named points in a study — day 1, day 3, the last day — as a set of
closed-response items (multiple choice, Likert), with the answers uploaded as ordinary observations.
Which surveys exist, what they ask, and when they appear all declared in the study bundle, so a new
survey needs a new bundle rather than a new build.

## Why it matters

The sensors measure what happened; they cannot measure what the participant knew, believed or felt.
For Epigames specifically the research output *is* a survey: whether a week of playing changed
anyone's understanding of transmission and protection is not observable in a contact log. Without
instruments the study is a game with telemetry attached.

It is also the second module, which is the one that proves the module boundary is real. Proximity
was designed against, so a module built to the same interface without changing that interface is
the evidence that [ADR-0001](../../docs/adr/0001-monorepo-and-package-boundaries.md) holds.

## What is already in place

**Considerably more than half of it.** This is largely an app-side task.

- **The observation contract is written and tested.**
  [`contracts/observations/instruments/survey_response/1.0.0.json`](../../contracts/observations/instruments/survey_response/1.0.0.json)
  already models everything asked for and a good deal more: `instrument_id`, `instrument_version`,
  `channel`, `answers[]`, `scores`, `partial`, `duration_ms`, `language`, with `valid.json` and
  `invalid.json` fixtures.
- **The server already validates it.** `Contracts.@payload_validators` maps the survey schema URI to
  `:validate_survey_response`, so responses are stored `validated: true` today. No server change is
  needed to store, validate or query them.
- **Answers are modelled correctly for this use.** `answers` is an array of
  `{item_id, status, value}` rather than a map, so study-defined item ids are *data*, not schema
  keys — no `additionalProperties` problem, and no contract change per survey.
- **Missing data is already a first-class distinction.** `status` separates
  `answered | skipped | refused | not_applicable | not_reached | timed_out`, and `assigned_for`
  exists precisely for a day-3 survey answered on day 5.
- **`modules` in the bundle contract is open by design** — *"adding a module must not require a
  change to this schema"* — so an `instruments` block needs no bundle schema change.
- **`EmbeddedModule` is a three-method interface** (`start`, `stop`, `status`) and `ModuleContext`
  already hands a module its own config block and an `ObservationRecorder`. Enrolment already
  refuses a bundle naming a module the binary lacks.

## What actually needs building

1. **An instrument definition contract.** This is the real gap. `survey_response` deliberately does
   not validate answer values: *"Item types live in the instrument definition, which versions
   independently."* That document does not exist. It needs to express items, their type
   (`single_choice`, `multi_choice`, `likert`), their options or scale bounds, and their prompt
   text — with versioning, because instruments get revised mid-study more often than anyone plans.

2. **`packages/epidemica_instruments`** — an `EmbeddedModule` with `id: "instruments"` that reads
   its config block, decides what is due, presents it, and records the response. The rendering
   widgets can live here too; nothing about them is Epigames-specific.

3. **Presentation in `apps/epigames`** — a route to an instrument, and something on the main screen
   saying one is waiting.

4. **A bundle block** and an instrument or two in `studies/epigame7`.

## The decisions that actually need making

### Where the instrument definition lives

The `survey_response` contract already assumes instruments version *independently* of the bundle,
which is the more considered position and worth honouring rather than quietly contradicting.

Putting the questions inline in the bundle is simpler — one document, already hash-verified,
already on the device, works offline. But it couples `instrument_version` to the protocol hash, and
**a study's identity is its bundle**: fixing a typo in one question changes the hash, which creates
a *new study* that participants must re-enrol into. That is not hypothetical; it is the same
constraint that makes parameter tuning require a re-join.

Fetching definitions separately, versioned on their own, avoids that at the cost of another
document to serve, cache and hash. Given that mid-study revision is explicitly anticipated by the
contract, this is probably the right shape — but the bundle should still name which instruments a
study uses and pin their versions, or a study stops being reproducible.

### Who decides it is day 3

Two options, and the wrong one is subtly broken.

*On the device.* The bundle carries `schedule.starts_at`, so the app can compute the study day
itself. Works offline and needs nothing new — but it is a **second implementation of "which day is
it"**, and the server already has one in `Studies.day_at/3`. That is exactly the class of bug in
[`0001`](../backlog/0001-configurable-tick-interval.md) item 2, where a study with a short tick
computed one day in one place and a different day in another. If the device computes it, it must use
the study's `tick_interval_seconds` and the `DeviceClock` offset, not `DateTime.now()` and a
hardcoded day.

*On the server.* The state channel already delivers a per-participant document; a `surveys_due`
field would make the server authoritative, and it already knows the day exactly. The cost is that
it only updates when something recomputes state — currently a tick — and it needs connectivity.

### How the participant finds out

**There is no notification dependency anywhere in the repository.** Without one, a survey is only
seen when the participant next opens the app, which for a study running over days means "eventually,
maybe". Local notifications are OS-scheduled, so unlike upload they do *not* depend on
[`0006`](../done/0006-no-background-sync.md) — but they need a package, permissions on both
platforms, and a sentence in the consent screen. Response *upload* is unaffected either way:
a participant answering a survey is by definition in the foreground, so the outbox drains on the
spot.

### What a survey module reports as its status

`ModuleState` is `sensing | stopped | permission_denied | radio_off`. A survey module is none of
these. `sensing` would be false, `stopped` misleading. Either add a state meaning "running, nothing
to do" — a `module_status` contract change — or let a module decline health reporting. This has no
effect on the twin, because `Health.insufficiently_observed` is called with the proximity module
specifically, but the record should not contain a claim nobody meant.

## Traps

**Keep it to closed responses, and enforce it in the contract.** The `survey_response` schema warns
that free text *"can contain PII that no schema can prevent"* and that the store is then
*"pseudonymous by policy, not by construction"*. Multiple-choice and Likert items keep that promise
structural. If the instrument definition contract simply has no free-text item type, no study can
accidentally break it — which is a much stronger guarantee than a note in a README.

**One response per instrument.** Nothing currently stops a participant answering twice. Completion
has to be tracked on the device, and it must survive a restart — and deliberately *not* survive
`withdraw()`, which wipes local state by design.

**Consent has to cover the questions.** The info screen describes proximity collection. Asking
people things is a different act, and the screen should say what will be asked before they join,
not when the first survey appears.

**A survey adds a second `module_status` stream.** `ModuleHealthReporter` emits one observation per
running module per interval, so enabling instruments doubles health traffic for no coverage benefit.

## How it would be verified

- Contract tests for the instrument definition, with valid and invalid fixtures, following the
  existing rules: every invalid fixture carries a `why`, and each fails on exactly one path.
- A round-trip test: an instrument definition plus a set of answers produces a payload that
  validates against `survey_response` — and, seeded with a defect, does not.
- Scheduling tests against a fake clock: due on the right day, not due before, still offerable
  after with `assigned_for` set to the day it was assigned.
- Answering twice records one observation.
- A skipped item records `status: "skipped"` rather than a null value, and abandoning records
  `partial: true` with `not_reached` for the remaining items.
- End to end on the debug study ([`studies/epigame-debug`](../../studies/epigame-debug)), where a
  seven-round game takes half an hour: a survey scheduled for round 1 and another for round 7 should
  both appear and both arrive server-side as `validated: true`.
