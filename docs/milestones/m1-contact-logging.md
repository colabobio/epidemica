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

**Decided and implemented (W4).** 32 random bytes, base64url-encoded, stored only as a SHA-256 hash
so a leaked database yields no usable credentials. Access tokens last 30 days, refresh tokens a
year, and refresh rotates on use — a replayed refresh token then fails, which is evidence worth
having. Deliberately not a JWT: a self-contained token cannot be revoked without a denylist, which
would reintroduce the very lookup JWTs exist to avoid, and revocation matters more here than saving
one query.

## 4. Where app code lives

Settled in [ADR-0001](../adr/0001-monorepo-and-package-boundaries.md), which defines three tiers of
effort and makes **Tier 1 — no code at all — the target for the common case**. An institution ships
one app, not one app per study; which study a binary is running is decided by the join code and the
protocol bundle it fetches at enrollment.

The consequence for M1 is worth stating plainly, because it changes the shape of the work:
**contactlog is not an app.** It is a protocol bundle at `studies/contactlog/`, and the binary it
runs on is `apps/template`. M1 ships no study-specific Dart code, and that is the milestone's
sharpest test of whether Tier 1 works as described.

### 4.1 What an institution actually configures

"No code" does not mean "no build". An institution does a **one-time** setup before its first study
and then never touches the app again:

| Setting | Where |
|---|---|
| Bundle identifier, app name, icon, splash | Native project config |
| Signing certificates, store listings | Apple Developer / Play Console |
| Server base URL | Build configuration |
| **Module set** | Which module packages the binary embeds |
| Permission usage strings | `Info.plist` and `AndroidManifest` |

The accurate claim is therefore **no code, and no rebuild per study**. Every subsequent study is a
bundle authored in the console: no release, no store review, no participant update. That is the
whole payoff of Tier 1.

**The module set is the awkward one.** ADR-0001 records that a study only runs if its modules are
already in the binary, so the instinct is to embed everything that might ever be needed. But module
permissions are declared at build time and are read by app reviewers and by participants at install.
A binary declaring Bluetooth, background location, camera and health data "just in case" invites
store-review scrutiny and looks alarming on the permission sheet. There is a real tension between
*one binary runs every future study* and *a minimal, justifiable permission surface*, and an
institution has to choose a portfolio, not a maximum.

Two consequences for how `apps/template` is built:

1. **Each module documents its own platform requirements** — the exact `Info.plist` keys, manifest
   permissions and background modes it needs, and a usage string general enough to cover any study
   that uses the module. This is the authoritative list an institution copies from, and later the
   input to a generator.
2. **Native manifest entries should eventually be generated from the module list**, not hand-
   maintained. With one module, M1 writes them by hand; the requirement is recorded here so that the
   template is not structured in a way that makes generation impossible (see §8).

## 5. Work items

### W1 — `epidemica_proximity` (federated plugin)

Lift the Herald integration out of `epigames-app` into `epidemica_proximity_android` and
`epidemica_proximity_ios`, against the platform interface W2 defines.

**W2 shrank this work.** Because banding moved to Dart, six native files — `DistanceEstimator`,
`CoarseDistanceModel`, `SimpleKalmanFilter` on both platforms — do not move at all. Native now does
three things per platform: supply the payload, run the sensor, bridge the channels. Native reports
raw RSSI and nothing else.

**Packaging: four packages, endorsement-based.** An app depends on `epidemica_proximity` alone and
gets Herald, the Kotlin service and the Swift lifecycle with no native edits. The reason to federate
rather than ship one package with two native folders is specific to this project: an institution
that needs a different radio — dedicated badges, or a nationally mandated stack — registers its own
`ProximityPlatform` instead of forking, which ADR-0001 forbids. Herald types appear in exactly two
packages, which also contains the risk below.

**Herald is unmaintained.** v2.2.0 is the latest release on both platforms and the last commits are
roughly three years old; the READMEs claim testing only to iOS 14.6 and Android 10. It remains the
best-validated BLE proximity stack in existence and its efficacy data is why we use it, but there is
no upstream to fix an OS regression. Containment is the mitigation, and it is why the wire format is
specified independently of Herald.

**Android gets its platform requirements for free; iOS cannot.** A plugin's `AndroidManifest.xml` is
merged into the host app, so permissions and the foreground service arrive automatically. iOS has no
equivalent: `Info.plist` keys must be in the app target. So the iOS package checks its own
`Info.plist` at `start()` and refuses with a list of what is missing. Without that check the failure
is silent — no crash, just no sensing once the screen locks, discovered at analysis time.

**Location is requested only where the platform forces it.** `BLUETOOTH_SCAN` is declared
`neverForLocation`, and `ACCESS_FINE_LOCATION` is capped at `maxSdkVersion="30"`. On Android 12 and
later a participant never sees a location prompt, which removes a consent and app-review liability
the module does not need.

**Swift Package Manager, verified rather than assumed.** Herald resolves cleanly via SPM at 2.2.0.
A CocoaPods podspec stays as the fallback path.

**The wire format is a contract with shared vectors.** `contracts/wire/proximity_payload/1.0.0.md`
plus `1.0.0.vectors.json`, decoded by both the Kotlin and Swift implementations in their own test
suites. Two implementations that can only meet on real hardware are otherwise free to disagree about
byte order or trailing data, and the symptom is two phones side by side detecting nothing, with no
error anywhere. The payload is 18 bytes — version, 16-byte pseudonym, device class — down from
Epigames' 28, with every simulated epidemiological field removed rather than zeroed.

One rule in that spec cannot be retrofitted: **readers must ignore trailing bytes.** It is what lets
a future version append an opaque application extension — which is how Epigames could migrate onto
this module without forking it — while already-deployed builds keep detecting updated ones.

- [x] Wire format specified and held to shared vectors by both native implementations
- [x] No epidemiological field appears anywhere in the public API or on the wire
- [x] The platform packages have no dependency on `epidemica_core`
- [x] Distance estimation is behind a `DistanceEstimator` interface with the `CoarseDistanceModel`
      thresholds as the default — delivered by W2, in Dart
- [x] Detections observed while Dart is detached are buffered and any overflow is reported, not
      silently dropped
- [x] Missing iOS `Info.plist` requirements are reported rather than failing silently
- [x] The package README states its **platform requirements verbatim** — every `Info.plist` key,
      Android permission and background mode, with usage strings written to cover any study that
      uses proximity rather than this one. This is what an institution copies into its build, and
      what a manifest generator will later consume
- [ ] A bare example app builds and runs on both platforms with no monorepo path assumptions
- [ ] One iOS and one Android device discover each other within 30 s
- [ ] Detections continue with the app backgrounded for ≥ 30 minutes on both platforms
- [ ] iOS relaunch via BLE state restoration resumes detection with no user interaction — the
      stale-`sensorArray` handling in `SimulationService.start` is hard-won and must not regress

Open: the Android plugin is Kotlin, and Flutter now warns that plugins applying the Kotlin Gradle
Plugin will eventually fail to build. Herald for Android and the Epigames integration are both pure
Java, so rewriting these ~300 lines in Java would retire the warning and a toolchain dependency at
once.


### W2 — Episode aggregator

Turns a detection stream into `contact_episode` payloads: sliding window per peer, band assignment
by device class, gap bridging, episode capping. **This does not exist today** — Epigames keeps only
a `Map<String,int>` of unique peers in SharedPreferences — so it is new code, not a port.

**Packaging.** The aggregator is *part of* `epidemica_proximity`, not a module of its own. A module
is the unit that an app embeds at build time, declares platform requirements, owns a payload
contract, and is activated by the protocol bundle; the aggregator has none of those properties
independently, and no bundle would ever enable it separately from proximity sensing.

W2 therefore creates the first two of the four proximity packages. `packages/` did not exist yet, so
this is also where the Dart workspace begins. **Native pub workspaces, not melos**: Dart 3.12 has
workspace support in the SDK, giving one lockfile and one `.dart_tool` with no tool to install.
Melos can be layered on later if cross-package scripting is needed.

```
pubspec.yaml                                      workspace root, no code
packages/
  epidemica_proximity_platform_interface/         tiny: the Dart↔native boundary
    lib/src/device_class.dart
    lib/src/proximity_detection.dart              the record the aggregator consumes
    lib/src/proximity_platform.dart               abstract class W1 implements
  epidemica_proximity/                            the module
    lib/epidemica_proximity.dart                  public API
    lib/src/episode_aggregator.dart               ← W2's substance
    lib/src/distance_estimator.dart               median + Kalman + threshold table
    lib/src/distance_bands.dart
    lib/src/aggregator_config.dart                the bundle's on_device / upload blocks
    lib/src/contact_episode.dart                  the payload
    lib/src/open_episode_store.dart               in-flight state across restarts
    lib/src/pair_key.dart
    test/                                         ← 34 tests, no device
  epidemica_proximity_android/                    W1
  epidemica_proximity_ios/                        W1
```

Defining `ProximityDetection` in the platform interface now, rather than in the module, means W1 has
no types to move when it arrives. The interface package is a few dozen lines.

**Distance estimation moved from native to Dart.** Epigames banded RSSI in Swift and Kotlin. Here
the native layer reports `(peer, rssi, timestamp, device class)` and nothing else, and the median,
Kalman and threshold stages are a Dart port carrying the same constants — recorded as
`estimator: coarse_distance`, `estimator_version: 2.0.0`. This shifts work from W1 to W2, which is
the right direction: it is the step where the measurement is actually made, and in Dart it runs in
CI instead of on a pair of phones. It also means W1 has one fewer thing to get right twice.

**The aggregator is a plain class**: detections in, episodes out, no clock and no I/O. A thin
adapter wires it to `epidemica_core.record()` when W3 lands. Keeping the two separate is what makes
the banding logic testable without a database, a mock, or a device.

**Three time thresholds, because turning instants into durations is where this can go wrong.**

| Threshold | Default | Decides |
| --- | --- | --- |
| `sample_credit_seconds` | 90 | The most observation time one sighting may vouch for |
| `dropout_threshold_seconds` | 75 | A longer silence is counted in `gap_count`, lost time or not |
| `max_gap_seconds` | 600 | A longer silence ends the encounter instead of bridging it |
| `max_episode_seconds` | 900 | Longer encounters are cut here and marked `truncated` |

`sample_credit` is the one that matters. A sighting is evidence about an instant; crediting a
ten-minute silence as ten minutes of proximity would manufacture exactly the sustained-contact
signal a transmission study is looking for. Separating it from `dropout_threshold` also lets the
payload distinguish *a dropout happened* from *time was lost*, which are different reliability
facts.

**In-flight episodes are persisted.** iOS relaunches the app through BLE state restoration and
Android kills background processes freely, so process death mid-encounter is normal rather than
exceptional. Holding open windows only in memory would lose them — and the loss would not be random:
it falls preferentially on *long* encounters, skewing precisely the contact-duration distribution
the Oxford study exists to measure. `OpenEpisodeStore` is the interface; the SQLite implementation
comes with W3, which owns the database.

**The fixtures are now generated from aggregator runs.** `contact_episode/valid.json` was
hand-written, which meant it described payloads the module might never emit — and one case had its
`rssi.min` above its `rssi.max`. It is now a golden file produced by real runs and still validated
against the schema by the Python and Elixir suites, so "everything this module emits is valid" is a
checked statement rather than a hope. One hand-written case is kept for a shape the aggregator
cannot produce but the schema must keep accepting: optional estimator detail sent as explicit null.

- [x] Runs entirely in CI over synthetic detection streams, with no BLE and no devices
- [x] Every emitted payload validates against `contact_episode/1.0.0.json`
- [x] Each instance in `contracts/fixtures/.../contact_episode/valid.json` is reproducible from a
      corresponding synthetic detection stream
- [x] A continuous 40-minute encounter yields ≥ 3 episodes, all but the last with `truncated: true`
- [x] A 5-minute dropout mid-encounter yields `gap_count ≥ 1` and `observed_seconds < wall_seconds`
- [x] **Band seconds never sum to more than the wall-clock duration** — the aggregator must not
      invent observation time it did not have
- [x] Identical detection stream produces byte-identical episodes
- [x] An encounter interrupted by process death is recovered from the open-episode store, not lost
- [x] Aggregator behaviour is driven by the bundle's `proximity.on_device` and `proximity.upload`
      blocks — the same binary, given different minimisation settings, produces different episodes
      without a rebuild

Verified by seeding a defect: removing the `sample_credit` cap — the one change that makes the
aggregator invent observation time — fails three independent tests, including the invariant and the
generated fixture.

Deferred to W1, where a real radio makes them answerable: whether an episode that could not be
resumed after process death should be re-opened or closed out as `truncated`, and whether 90 s of
sample credit is right for Herald's actual detection cadence on each platform.


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
- [ ] **Enrollment checks the bundle against the module registry** and fails when the bundle names a
      module this binary does not embed. Silently enrolling into a study the app cannot service is
      the worst available failure: it looks successful and is only discovered at analysis, by which
      time the collection window has passed

### W4 — `epidemica_server`

Phoenix. Studies and join codes, enrollment and tokens, the ingest endpoint, ack, health, the
`observations` table and a `contacts` projection. Payload validation via **exonerate** (MIT, drafts
4/6/7/2019/2020) — its compile-time model matches the quarantine design, since a schema the release
was not built with cannot be validated and is therefore quarantined until redeploy.

- [x] A conformance suite driven from `contracts/api/ingest/v1.yaml` and the existing fixtures,
      which are reused directly as request bodies
- [x] Every `envelope/valid.json` fixture is accepted
- [x] Every `envelope/invalid.json` fixture is **stored, not lost** — quarantined where it can be
      identified, rejected only where `(device_id, seq)` is unusable, and never a 500 or a
      whole-batch failure
- [x] Unknown `schema_uri` stores the observation with `validated=false` and
      `reason: unknown_payload_schema`
- [x] Repeated `(device_id, seq)` yields `duplicate` and exactly one stored row
- [x] A batch whose `device_id`, `study_id` **or `subject`** disagrees with the token is refused and
      stores nothing
- [x] The Elixir validator agrees with the Python validator on all 65 contract fixtures — a contract
      that meant different things on the client and the server would fail in the field, which is the
      most expensive place to discover it
- [x] Gzipped and uncompressed request bodies are both accepted
- [x] The `contacts` projection can be dropped and rebuilt from `observations` with an identical
      result
- [x] `mix release` builds, migrates and serves on a bare host with Postgres, with no AWS service of
      any kind

> **Two criteria corrected during implementation.**
>
> The invalid-fixture item originally read "every invalid fixture is quarantined". That is wrong: an
> observation with a negative `seq` cannot serve as an idempotency key, so there is no key under
> which to store it and `rejected` is the correct outcome. Quarantine requires that the observation
> can at least be identified.
>
> The binding item originally checked only `device_id` and `study_id`. Omitting `subject` would have
> let a device write observations attributed to another participant in the same study — the exact
> mis-attribution the check exists to prevent. The ingest contract was updated to match.

### W5 — `apps/template` and `studies/contactlog`

The generic app binary, plus the protocol bundle that makes it a contact-logging study. The bundle
is the deliverable that a researcher would author; the binary is the platform's.

- [ ] Join by code enrolls, fetches the protocol bundle, and records its hash on every observation
- [ ] Permission flow for Bluetooth and background execution on both platforms
- [ ] Visible state: enrolled, scanning, last sync, pending observation count
- [ ] **`studies/contactlog/` contains no Dart code** — only a protocol bundle. If the milestone
      cannot be completed without study-specific application code, Tier 1 does not work as described
      and ADR-0001 needs revisiting
- [ ] The same binary, given a different bundle, collects a different module's data without a rebuild
- [ ] A bundle naming an absent module is **refused with an actionable message** ("this study needs a
      newer version of the app"), and the participant is never left enrolled in a study that collects
      nothing
- [ ] Withdrawing stops collection and clears local data

## 6. Sequencing

```
W2 (aggregator) ─┐
                 ├─→ W5 (template + bundle) ─→ milestone acceptance
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
- Whether a study can genuinely be a protocol bundle rather than a build, which is the premise Tier 1
  rests on and the one M1 is most likely to falsify

Each of those is worth writing down at the end, whichever way it goes.

## 8. Deferred, with reasons

Surfaced while planning M1, deliberately not in it. Recorded so they are decisions rather than
oversights.

| Item | Why deferred | When it becomes blocking |
|---|---|---|
| **Rotating BLE identifiers** | M1 broadcasts a stable pseudonym (§3.1), which is adequate for a consenting internal pilot | Immediately after M1. Any EU deployment, and the Oxford observational cohort, need this first |
| **Generated native manifest entries** | With one module, hand-written entries are cheaper than a generator | The second or third module, when hand-maintained plists start drifting from what the app actually does |
| **Third-party payload schema validation across institutions** | While institution and server owner are the same party, a module's schema can simply be compiled into that institution's server | The first study spanning two institutions. A collaborator's server not built with your schema quarantines every observation from your module *permanently* — the quarantine behaves correctly, but no upgrade is coming to release it |
| **ADR-0005 (token lifetime and rotation)** | M1's opaque device-bound token satisfies the ingest spec without prejudging the policy | Before any deployment outside the lab |
| **ADR-0006 (protocol bundle format)** | M1 needs a minimal bundle; formalising it before a second module exists would be guessing | The second module, when the bundle has to express interactions between modules |
| **A second institutional deployment** | Not needed to prove the vertical slice | Sooner than feels necessary. Being the only user is how a platform ends up working only for the team that built it, and a second deployment — even a fictional one on the same hardware, with its own config, app identity and study — surfaces multi-tenancy assumptions long before Leibniz finds them |
