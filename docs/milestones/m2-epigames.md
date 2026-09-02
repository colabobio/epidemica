# M2 — Epigames as a digital twin

## 1. Goal

A seven-day game in which participants carry a phone, choose whether to protect themselves, and
score points — while a Starsim simulation running on the server decides who actually gets infected,
using the contact network the participants themselves produce.

This is the first **Tier 2** study: it uses the platform's modules and server unchanged, and adds
its own screens and its own rules. It is deliberately not a port of the existing Epigames codebase,
which has accumulated more mechanism than the concept needs. It is a re-statement of the idea in its
simplest defensible form, to be refined in the field.

It also abandons the roadmap's **edge transmission model** (§5.4). Reasons, in order of weight:

1. A server-side network aggregates *both* sides of every encounter, so contact estimation is better
   than anything one phone can do alone.
2. Transmission depends on the peer's protection state, which a phone cannot know.
3. The population can be completed with virtual participants, so a study of twenty people still
   produces epidemic dynamics.
4. One implementation instead of two, with no cross-language equivalence testing to maintain.

The cost is a new capability the roadmap did not anticipate: **the app must be able to ask the
server what has happened to its participant.**

## 2. Milestone acceptance

Twenty participants over seven days produce a game in which:

1. every infection is attributable to a specific reconciled contact or virtual-population event in a
   recorded, re-runnable tick;
2. re-running any tick from its stored inputs reproduces its outputs exactly;
3. no participant's state or points ever change retroactively;
4. the same binary, given the `contactlog` bundle instead, collects contact data and shows no game.

Criterion 4 is the Tier 2 claim: Epigames is a *custom app*, but the modules underneath it are the
platform's, unmodified.

## 3. Decisions taken

### 3.1 Contact reconciliation — union of intervals

A sees B and B sees A: two episodes, same `pair_key`, different durations, because detection is
asymmetric. **Contact happened when *either* side saw it**, and one-sided reports are counted and
flagged.

A study that later wants to be strict can filter on the flag; a study that discarded them cannot get
them back. This is the single most consequential number in the milestone, and it is now a stated
rule rather than an accident of implementation.

### 3.2 Virtual participants may infect real ones — yes, with disclosure

With twenty players and no virtual transmission there is no epidemic to observe. A participant can
therefore be infected by something that does not exist, so the information screen and the consent
text must say the study includes simulated participants.

### 3.3 Death — built, unused

The `dead` state and the black screen are implemented so the state contract does not need widening
later, but the default Starsim SIR model produces no deaths. Nothing in M2 will show it.

### 3.4 Contact points are immediate — so protection goes on the wire

Scoring a contact needs the peer's protection state at the moment of contact, which only the radio
can supply in time.

**This is the trailing-byte extension the wire format reserved**, and it must be spent carefully.
Epigames does not get a field in the proximity payload — that would put an application's vocabulary
back into a general module, which is exactly what the format was cleaned up to remove. Instead the
module gains an **opaque application extension**: the app supplies bytes to advertise, receives the
peer's bytes back, and the module never interprets either. Epigames encodes protection in one byte;
`contactlog` sends none and is unaffected.

**Two ledgers are not created.** The `POINTS` figure comes only from the server state document. The
app shows a transient acknowledgement of a scoring contact and a small pending tally; it never
maintains its own score. Immediate feedback without two sources of truth that can disagree.

### 3.5 Population, tick and timezone

Population size is a bundle parameter. The tick interval is a bundle parameter, fixed at one day for
this study. Ticks run on the **server's** timezone — sufficient for a single-site pilot, and
recorded in the deferred register as the thing a multi-site game would have to revisit.

### 3.6 Protection efficacy — parameterised at 1.0

Protected means immune, which is the clearest rule for a game. Efficacy is a bundle parameter
defaulting to 1.0, so a later study can ask what partial protection does without a schema change.

### 3.7 Every reward is a parameter

Points for a healthy day, the cost of protection, and points per qualifying contact all come from
the bundle. A second game with different economics needs no rebuild — the Tier 2 equivalent of the
Tier 1 claim.

## 4. What is new, and what is not

**Reused unchanged:** `epidemica_proximity`, `epidemica_core`'s outbox, sync, enrolment and identity,
the ingest API, the bundle mechanism, `ContactNetwork` in `models/`.

**New platform capability — useful well beyond this game:**

- **The participant state channel.** The mirror image of the observation envelope: observations flow
  up carrying a `schema_uri` and an opaque payload; state flows down carrying a `state_uri` and an
  opaque state document. Core validates and caches it and never learns what an "epi state" is.
- **Module health observations.** An hourly `module_status` saying proximity is sensing. M1 deferred
  this; the Bluetooth mechanic needs it.
- **A job runner.** The server has no Oban yet.

**New and specific to this study:** the twin runtime, the game rules, and the app.

## 5. Work items

### W1 — The participant state channel

`GET /v1/participants/me/state`, scoped to the token's own participant, returning a document
validated against a `state_uri` the bundle names.

- [x] Contract `contracts/state/participant_state/1.0.0.json` plus the game's own state contract,
      with fixtures, validated in Python and Elixir like every other contract
- [x] `revision` increases monotonically; the app can tell a stale cached state from a current one
- [x] `as_of` states which tick produced it, so the UI can say how old it is rather than implying
      it is live
- [x] Core exposes it as a typed-but-opaque document and caches it; a study's vocabulary never
      enters `epidemica_core`
- [x] Offline returns the cached document with its original `as_of`, never a fabricated one
- [x] A token for one participant cannot read another's state
- [x] ADR recording the channel, since it makes the platform bidirectional

### W2 — Module health, and the protected-by-default rule

- [x] Contract `observations/health/module_status/1.0.0.json`: state
      (`sensing` | `stopped` | `permission_denied` | `radio_off`) and the window it covers. Which
      module is in the envelope, so the two cannot disagree
- [x] `epidemica_proximity` reports it hourly, in windows that abut
- [x] **Absence of a heartbeat, not the presence of an off-signal, is what marks a participant
      protected.** A killed app cannot report; the twin must never infer transmission through a
      device it was not hearing from
- [x] The reason is recorded even though the game treats all protection identically — research needs
      to tell a choice from a dead battery
- [x] A radio-state check, distinct from "is the sensor running". A running sensor with Bluetooth
      off produces no detections and is otherwise indistinguishable from a participant who met
      nobody
- [x] Server-side coverage: overlapping and duplicated windows are unioned, not summed, and a
      participant never heard from is reported as unobserved rather than omitted

**The module capability interface moved into `epidemica_core`.** `EmbeddedModule`, `ModuleContext`
and `recorderFor` were app-level glue in `apps/template`; a second Tier 2 app would have duplicated
them, and health reporting has to be generic rather than reimplemented per module. Core defines the
interface and depends on no module — which is the arrangement the roadmap's "module capability
interface" contract always implied.

**A heartbeat alone was not enough, and finding that out was the point of building this early.**
Reporting only whether the module was running would have marked a phone with Bluetooth disabled as
`sensing`. The twin would then have read its complete absence of contacts as an absence of exposure,
which is precisely the failure the rule exists to prevent. `ProximityPlatform.isRadioEnabled()` is
new on both platforms; iOS takes it from Herald's own state callback rather than instantiating a
second `CBCentralManager`.

### W3 — Contact reconciliation

- [ ] A daily reconciled network per study: pair, union-of-intervals duration, band seconds, and
      whether both sides reported
- [ ] Deterministic — the same observations always produce the same network
- [ ] Rebuildable from observations, like every other projection
- [ ] Late-arriving observations enter the projection but never a tick that has already run

### W4 — The twin runtime

Elixir orchestrates; Python simulates. An Oban job per study-day writes the day's network, protection
states and participant roster to a file, runs the Starsim tick as a subprocess, and applies the
result in one transaction.

A subprocess rather than a service because a daily tick is a batch job: nothing to supervise, no RPC
failure modes, and re-running the exact command with the same inputs is the reproducibility story.

- [ ] Each tick stores its inputs, its seed and its outputs; re-running reproduces them exactly
- [ ] Ticks are immutable — a tick is never recomputed, and no participant's history changes
- [ ] A tick that fails leaves no partial state and can be retried
- [ ] Virtual participants complete the population to the bundle's size, following ADR-0012's
      pre-allocated pool with an `active` state
- [ ] Every infection records its cause: a reconciled contact, or a virtual-population event
- [ ] The Starsim version is recorded on every tick

### W5 — Game rules

Server-side, because points depend on state the client cannot see, and because a client-computed
score is a client-editable score.

- [ ] 2 points a day while healthy; none while infected
- [ ] Protection costs 1 point a day, grants immunity, and expires after the bundle's window
- [ ] A qualifying contact between two unprotected participants awards 5 points to each, subject to
      a cooldown
- [ ] Points and epi state are derived from ticks and are reproducible from them
- [ ] Every rule constant comes from the bundle — a second game with different economics needs no
      rebuild

### W6 — `apps/epigames` and `studies/epigame7`

- [ ] A solid-colour screen: green healthy, red infected, blue recovered, black dead, with
      **POINTS n** centred and a shield when protected
- [ ] Total cases so far, from the state document
- [ ] Buttons to take and release protection, and to leave the study
- [ ] An information screen at enrolment covering the rules **and the presence of simulated
      participants**
- [ ] Visible staleness — the participant is told their state is from the last daily update, not now
- [ ] The app contains no epidemiology: it renders a state document and posts actions
- [ ] `studies/epigame7/` contains no Dart

## 6. Sequencing

W1 first — it is the platform capability, it is useful without the game, and everything else waits
on it. W2 next, since the twin cannot be trusted without knowing which devices were sensing. W3 and
W4 together, because a reconciliation rule is only testable against a tick. W5 and W6 last.

W1 and W2 are worth building even if Epigames is deferred.

## 7. What M2 tests that M1 did not

- Whether the platform can carry a study whose value depends on **feedback**, not just collection
- Whether a Tier 2 app is genuinely thinner than a bespoke one, or whether writing custom screens
  drags study-specific logic back into the packages
- Whether server-side reconciliation of two-sided contact data actually beats one phone's view
- Whether `ContactNetwork` holds up driving a live simulation rather than replaying a finished one

## 8. Deferred register

- **Multi-timezone ticks.** M2 uses the server's timezone. A multi-site game cannot, and the answer
  changes what "day 3" means for a participant.
- **Partial protection efficacy.** Parameterised, defaulted to 1.0, unexercised.
- **Death.** Implemented in the state contract and the UI, unused by the default SIR model.
- **Live simulation between ticks.** Everything here is daily. A continuous twin is a different and
  much larger design.
- **Pooling Epigames networks with observational ones.** The contact reward means this measures
  *incentivised* contact. Someone will eventually try to pool it with an Oxford-style cohort; the
  datasets should carry something that makes that visibly wrong.
