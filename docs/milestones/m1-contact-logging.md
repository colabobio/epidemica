# Milestone 1 — Contact logging end to end

> **Status:** planned. Two decisions (§3) must be settled before W1 or W5 start.

## 1. Goal

One study app that asks a participant to join with a code, then logs Bluetooth proximity between
participants and delivers it to a self-hosted server. Nothing else.

The point is not the app. The point is to build the first vertical slice through every layer of the
platform — contract, module, core, server, analysis — so that the layers are proven against each
other before more modules are added on top of them.

**Explicitly out of scope:** transmission modelling, instruments and surveys, multi-channel reach,
the GraphQL researcher console, rotating BLE identifiers, FAIR export packaging, and any protocol
bundle content beyond what one module needs.

## 2. Milestone acceptance

Five devices in one room for one hour produce a contact network in Postgres that:

1. passes `analysis/` contract validation on export, and
2. loads into `EpidemicaNetwork` and runs a Starsim `ss.SIR` simulation to completion.

The second criterion costs almost nothing, since the Starsim bridge already exists, and it closes
the whole loop: contract → module → app → server → analysis → model. If the measured network cannot
drive a simulation, something upstream is wrong in a way no unit test will reveal.

## 3. Decisions needed before starting

### 3.1 Peer identity over Bluetooth — **blocks W1 and W2**

`contact_episode.peer` requires a pseudonym matching `^[A-Za-z0-9_-]+$` with at least 8 characters.
Epigames broadcasts a compact server-assigned integer, which cannot satisfy that.

| Option | Cost | Consequence |
|---|---|---|
| **Broadcast the 16-byte pseudonym** (fits Herald's 28-byte payload) | Lowest; `peer` maps directly | Pseudonym is linkable in the clear over BLE |
| Compact id + client-side roster | Roster download and refresh | Every device learns the full participant list |
| Compact id + server-side resolution at ingest | Server work; contract revision | `peer` semantics change |

**Recommendation for M1: broadcast the pseudonym**, and treat rotating identifiers as deferred work.

> **This makes M1 undeployable outside an internal pilot.** A stable identifier broadcast in the
> clear is a re-identification and linkability risk that will not pass a German DPIA and is not
> appropriate for the Oxford observational cohort. M1 is for consenting team members and a lab
> pilot. Rotating identifiers are a prerequisite for any real deployment and should be scheduled
> immediately after, not "eventually".

### 3.2 Participant token scheme — **blocks W3 and W4**

ADR-0005 is unwritten. For M1, an opaque random token stored server-side, bound to one device and
one study, revocable, with a long expiry. This is enough to satisfy the ingest spec without
prejudging lifetime or rotation policy, which is where the real ADR-0005 questions live.

## 4. Where app code lives

The question behind the question is what building an Epidemica app should feel like. Three tiers,
and the layout follows from them.

| Tier | Who | What they do | Needs |
|---|---|---|---|
| **1. No code** | Most studies | Define a protocol bundle in the console, hand out a join code, participants use a generic Epidemica app | Protocol bundle + a study-agnostic app binary |
| **2. Custom app** | Studies needing their own branding, store presence or extra screens | Start from the template, add the module packages they need, ship under their own developer account | Published packages + a template |
| **3. New module** | Groups contributing a new data type | Write a package against the module interface plus a payload contract | Module interface + contract conventions |

**Tier 1 is meant to be the common case.** That has a direct consequence for M1: the app should be
built as *the template configured by a one-module protocol bundle*, not as a bespoke contact-logging
app. Slightly more work now, but it is not throwaway work — it is the template.

### Decision

**Platform-owned apps live in the monorepo at `apps/`** — `apps/template`, and later `apps/epigames`
and `apps/travelhealthy`. M1's app is `apps/contactlog`, built as a thin configuration of the
template. This keeps the dogfooding gate real: a contract change breaks the app in the same pull
request that made it.

**External apps live in their own repositories** and depend on published packages. That path is not
needed for M1, but it must not be allowed to rot, which is the classic way a platform ends up
working only for the team that built it.

**Nothing is ever a fork of the monorepo.** Forking would give every study its own divergent copy of
the platform, make upstream fixes a permanent merge burden, and make "which version of the platform
produced this data" unanswerable — which would quietly undermine the reproducibility that
`protocol_hash` exists to provide. It is the same fork problem the platform is being built to
eliminate.

### Keeping the external path honest

While everything is still in the monorepo, one cheap CI job proves the outside-in path works: copy
`apps/template` to a directory *outside* the workspace, resolve the Epidemica packages as git
dependencies pinned to the current commit, and build it. If that job fails, the packages have grown
a dependency on monorepo-relative paths and Tier 2 is broken without anyone noticing.

The trigger to actually publish to pub.dev and split out `epidemica-app-template` is whichever comes
first: the first external group wanting to build an app, or the start of Phase 2.

> This section records a decision that is expensive to revisit and should be promoted to an ADR
> (extending ADR-0001, which defines the monorepo but not app hosting) once confirmed.

## 5. Work items

### W1 — `epidemica_proximity` (federated plugin)

Lift the Herald integration out of `epigames-app` and into a real plugin: `_platform_interface`,
`_android`, `_ios`. Swift and Kotlin move across substantially unchanged. The BLE payload is reduced
to identity only — no `epi`, `clin`, `mod`, `strain`, `ps/pi/pr`. The plugin exposes a stream of
`ProximityDetection` records (`peer`, `rssi`, `observed_at`, `peer_device_class`).

- [ ] A bare example app builds and runs on both platforms with no monorepo path assumptions
- [ ] One iOS and one Android device discover each other within 30 s
- [ ] Detections continue with the app backgrounded for ≥ 30 minutes on both platforms
- [ ] iOS relaunch via BLE state restoration resumes detection with no user interaction — the
      stale-`sensorArray` handling in `SimulationService.start` is hard-won and must not regress
- [ ] No epidemiological field appears anywhere in the public API
- [ ] The platform packages have no dependency on `epidemica_core`
- [ ] Distance estimation is behind a `DistanceEstimator` interface, with the existing
      `CoarseDistanceModel` thresholds as the default implementation

### W2 — Episode aggregator

Pure Dart. Turns a detection stream into `contact_episode` payloads: sliding window per peer, band
assignment by device class, gap bridging, episode capping. **This does not exist today** — Epigames
keeps only a `Map<String,int>` of unique peers in SharedPreferences — so it is new code, not a port.

- [ ] Runs entirely in CI over synthetic detection streams, with no BLE and no devices
- [ ] Every emitted payload validates against `contact_episode/1.0.0.json`
- [ ] Each instance in `contracts/fixtures/.../contact_episode/valid.json` is reproducible from a
      corresponding synthetic detection stream
- [ ] A continuous 40-minute encounter yields ≥ 3 episodes, all but the last with `truncated: true`
- [ ] A 5-minute dropout mid-encounter yields `gap_count ≥ 1` and `observed_seconds < wall_seconds`
- [ ] **Band seconds never sum to more than the wall-clock duration** — the aggregator must not
      invent observation time it did not have
- [ ] Identical detection stream produces byte-identical episodes

### W3 — `epidemica_core`

Identity, enrollment, token storage, outbox, sync, clock. Harvest the background-execution knowledge
from `th-app`'s `survey_data_sync_service.dart`; the Android 14/15 foreground-service and headless
isolate landmines are already defused there.

- [ ] Pseudonym and `device_id` generated once, persisted, and stable across restarts
- [ ] Tokens held in platform secure storage, never in shared preferences
- [ ] Outbox is SQLite in WAL mode and is **writable from a background isolate** while the main
      isolate holds a connection
- [ ] `seq` is allocated inside the same transaction as the row insert; concurrent writes from two
      isolates produce no duplicates and no gaps
- [ ] Batches are ≤ 1000, gzipped, and honour `Retry-After` on 429 and backoff on 5xx
- [ ] Force-resending a delivered batch produces `duplicate` outcomes and no duplicated rows
- [ ] 24 hours offline loses nothing and uploads on reconnect
- [ ] `clock_offset_ms` is recorded, and is `null` rather than `0` when no reference was available
- [ ] `rejected` observations move to a local dead-letter store and are surfaced, never silently
      deleted

### W4 — `epidemica_server`

Phoenix. Studies and join codes, enrollment and tokens, the ingest endpoint, ack, health, the
`observations` table and a `contacts` projection. Payload validation via **exonerate** (MIT, drafts
4/6/7/2019/2020) — its compile-time model matches the quarantine design, since a schema the release
was not built with cannot be validated and is therefore quarantined until redeploy.

- [ ] A conformance suite driven from `contracts/api/ingest/v1.yaml` and the existing fixtures,
      which are reused directly as request bodies
- [ ] Every `envelope/valid.json` fixture is accepted
- [ ] Every `envelope/invalid.json` fixture is **quarantined** — not rejected, and never a 500
- [ ] Unknown `schema_uri` stores the observation with `validated=false` and
      `reason: unknown_payload_schema`
- [ ] Repeated `(device_id, seq)` yields `duplicate` and exactly one stored row
- [ ] A batch whose `device_id` disagrees with the token returns 403 and stores nothing
- [ ] Gzipped and uncompressed request bodies are both accepted
- [ ] The `contacts` projection can be dropped and rebuilt from `observations` with an identical
      result
- [ ] `mix release` runs on a bare VM with Postgres and Caddy, with no AWS service of any kind

### W5 — `apps/contactlog`

The template app, configured by a one-module protocol bundle.

- [ ] Join by code enrolls, fetches the protocol bundle, and records its hash on every observation
- [ ] Permission flow for Bluetooth and background execution on both platforms
- [ ] Visible state: enrolled, scanning, last sync, pending observation count
- [ ] **No study-specific logic in application code** — behaviour comes from the protocol bundle, so
      the same binary could run a different study
- [ ] Withdrawing stops collection and clears local data

## 6. Sequencing

```
W2 (aggregator) ─┐
                 ├─→ W5 (app) ─→ milestone acceptance
W4 (server) ─────┤
      └─→ W3 (core) ─┘
W1 (plugin) ─────────┘
```

**Start W2 and W4 in parallel.** Both are fully specified by contracts, neither needs hardware, and
both are likely to expose contract problems while those are still cheap to fix. W3 follows W4, or
runs against a stub. **W1 is the schedule risk** — BLE work is fiddly, needs device time, and cannot
be meaningfully tested in CI.

## 7. What this milestone is really testing

Beyond the app, M1 answers questions the plan has so far only asserted:

- Whether the contracts are precise enough for a server and a client to be built independently
  against them and interoperate on first contact
- Whether the quarantine design behaves sensibly when a real client and a real server disagree
- Whether "add a module" means only "add a contract and a package", per the ADR-0004 validation
  criterion that a new observation type requires **zero** changes to the ingest API
- Whether an app can be a thin configuration of a template rather than a bespoke build, which is the
  premise Tier 1 rests on

Each of those is worth writing down at the end, whichever way it goes.
