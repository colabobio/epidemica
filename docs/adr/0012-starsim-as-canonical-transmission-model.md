# ADR-0012: Starsim as the canonical transmission model

- **Status:** **Accepted** — Spike A passed 2026-09-02; empirical validation (Spike B) still outstanding
- **Date:** 2026-09-02
- **Deciders:** Colubri (PI), backend eng, mobile eng
- **Implementation:** `models/starsim_epidemica`, `contracts/observations/proximity/contact_episode/1.0.0.json`

## Context

Transmission logic currently exists on device:

- `epigames-app/lib/data/health_status.dart` — 2,398 lines, on-device, real-time.

This logic does not follow standard epi models, making it not usable by a modeller, neither supports 
in-silico scenario work or calibration, and the proposal's promise of "flexible epidemic models" is currently unverifiable.

[Starsim](https://github.com/starsimhub/starsim) (MIT, Python 3.11+, R bindings, v3.5.2, actively
developed by the Institute for Disease Modeling lineage behind Covasim/HPVsim/FPsim) is an
agent-based framework with first-class `Sim`, `People`, `Disease`, `Network`, `Intervention` and
`Analyzer` abstractions, explicit time types (`ss.dur`, `ss.rate`, `ss.time_prob`), and built-in
calibration and scenario tooling. The PI's stated goal is to move between in-silico Starsim
simulations and real-world deployments using the *same* underlying transmission models.

## Decision

We will adopt **Starsim as the canonical transmission model.** Epidemica will not define its own
epidemiology. Three roles, not three implementations:

| Runtime | Role | Scope |
|---|---|---|
| **Starsim (Python)** | Canonical authority | In-silico scenarios, calibration, power analysis, post-hoc replay, Aim 3 digital twin |
| **`epidemica_transmission` (Dart)** | Edge runtime | Real-time, offline, on-phone: per-contact hazard and *this participant's* state. Deliberately not a general ABM |
| **Elixir server** | Orchestration only | Scheduling, ticks, persistence, reconciliation. **No epidemiological logic** — `pathogen_properties.ex` math is retired |

Two bridges live in `models/starsim_epidemica`:

1. **Protocol → Starsim.** A study protocol's `transmission.pars` block is *directly* loadable as
   `ss.Sim(pars)`. The schema is constrained so that anything expressible in an Epidemica protocol
   is expressible in Starsim; Epidemica-only parameters are refused. This constraint is what keeps
   the round trip honest.
2. **Measured network → `ss.Network`.** `EpidemicaNetwork(ss.Network)` materialises observed
   `contact_episode` observations as a dynamic edge list (`p1`, `p2`, `beta` weighted by duration and
   estimated distance), plus an `ss.Analyzer` for export.

**Equivalence testing.** Cross-language determinism cannot come from a shared seed, because NumPy's
`Generator` and Dart's PRNG differ. Fixtures therefore **inject a pre-generated uniform stream**
alongside a fixed contact trace; both implementations consume draws in a specified order and must
produce identical state trajectories. Property tests over N synthetic traces additionally require
agreement within tolerance on attack rate, generation interval and offspring distribution.

**Sequencing.** Implement the Epigames model as an `ss.Disease` **first**, then port to Dart. The
specification then derives from working, testable Python rather than from prose.

## Consequences

**Positive.** The lab stops maintaining epidemiology and starts maintaining integration. One
authoritative model instead of two drifting ones. `EpidemicaNetwork` turns every deployment into a
drop-in empirical substrate for any Starsim disease module — RSV, TB, co-transmission — so a
collaborator can run a study over measured contact networks without our team writing epidemiology.
Calibration, scenarios and power analysis arrive for free. Aim 3's in-silico ↔ real-life loop becomes
the default path rather than a bespoke project.

**Negative.** A hard dependency on an externally governed, fast-moving project. The Dart edge runtime
must be kept demonstrably faithful to a moving target, and the equivalence fixtures are real ongoing
maintenance. Python enters the runtime picture for server-side replay, adding a deployment component.
Starsim's expressiveness may exceed what the edge runtime can support, so the protocol schema must
police a subset — and telling a collaborator "Starsim can do that but Epidemica's phone runtime
cannot" is a recurring conversation.

**Neutral.** Overlaps the role the proposal assigned to Opqua; see ADR-0013 (planned).

## Alternatives considered

| Alternative | Why not |
|---|---|
| Keep the bespoke Dart + Elixir model, add a spec and golden tests | Lower risk, but the lab keeps maintaining epidemiology forever, and no modeller can use it. Forfeits the in-silico goal entirely. |
| Opqua as canonical | Strong on genotype evolution, weaker on networks/interventions; smaller ecosystem. Better as a complement (ADR-0013). |
| Covasim | Superseded by Starsim, and COVID-specific. |
| EMOD / GAMA as canonical | Heavyweight; GAMA is the urban-space layer for Aim 3, not the transmission engine. |

## Open questions — resolved by Spike A unless noted

1. **Open populations — DECIDED.** Pre-allocated agent pool with an explicit `active` state.
   The sim is created with more agents than will ever enrol, every agent stays `alive`, and
   `OpenCohort.active` marks current membership; inactive agents form no edges. Starsim's
   births/deaths machinery was rejected because deaths are irreversible (a participant who pauses
   and resumes could not be represented) and because mortality results would be polluted by what is
   really an administrative event. Implemented and tested; the invariant *"nobody is infected while
   not enrolled"* is asserted in both the test suite and the spike.
2. **Edge subset scope — OPEN.** Which Starsim features the Dart edge runtime must support is not
   settled and does not block this ADR. To be resolved when the Dart port starts.
3. **Performance — ANSWERED, comfortably.** 1,000 participants x 28 days x 696k episodes builds in
   1.3 s and runs in 0.02 s. Roughly two orders of magnitude inside what a daily Aim-3 feedback
   loop needs. See `models/README.md` for the table.
4. **Version policy — ADOPTED.** Pin `starsim_version` per protocol-bundle major and record it in
   every export. Spike ran against Starsim 3.6.1 (the pin in `pyproject.toml` is `>=3.5.2,<4`).
5. **Upstream contribution — RECOMMENDED, not yet done.** `EpidemicaNetwork` is a generally useful
   empirical-network module; offering it to `starsimhub` costs little and buys visibility.

### Findings worth carrying forward

- **Starsim copies modules on registration.** A reference held from before `ss.Sim(...)` points at a
  dead object with uninitialised states. Sibling modules must be resolved from the sim after init.
- **Bulk Python objects must never be stored on a Module.** Starsim recursively walks module
  attributes at init to discover distributions and time parameters. Leaving ~145k episode
  dataclasses reachable made that walk traverse 9.6M objects and `sim.init()` take 58 s; flattening
  to NumPy arrays at construction cut it to 0.32 s with identical results. This is a general
  constraint on every future data-bearing module, not a quirk of this one.
- **No flu or COVID module exists in Starsim.** Core ships `SIR`, `SIS`, `SEIR`, `NCD`; the library
  adds Cholera, Ebola, HIV and Measles, which upstream flags as illustrative rather than
  research-grade. COVID is Covasim, a separate package. Respiratory work should start from
  `ss.SEIR` with study-specific parameters; adopting a research-grade respiratory model is a
  separate decision.

## Validation

**Spike A -- plumbing, open-cohort semantics, performance. PASSED 2026-09-02.**
Run `models/spikes/spike_01_plumbing.py`; it self-checks and exits non-zero on failure.

- [x] Every episode is consumed, with drops counted rather than silent.
- [x] Open-cohort invariant holds: nobody is infected while not enrolled.
- [x] Transmission occurs over measured contacts (224 infections from 5 seeds, 300 participants).
- [x] Rolling enrollment and dropout behave correctly.
- [x] Deterministic for a fixed seed.
- [x] Build + run within budget (0.34 s for 145k episodes; 1.3 s at 1,000 participants x 28 days).
- [x] Episodes conform to the `contact_episode` contract.

**Spike B -- empirical fidelity. NOT YET RUN; blocked on data.**
Spike A used synthetic episodes, so it validates the machinery and says *nothing* about whether
Starsim reproduces real Epidemica dynamics. Before any scientific claim rests on this bridge:

- [ ] Export a past Epigames deployment's contact log and epidemic curve.
- [ ] Reproduce the observed attack rate and curve shape within an agreed tolerance.
- [ ] Calibrate the band weights and `REFERENCE_EXPOSURE_S` against that deployment, replacing the
      current illustrative defaults.
- [ ] Confirm every parameter of the intended study pathogen has a faithful Starsim expression.

If Spike B fails, the fallback remains "spec plus golden tests over our own implementations", and
this ADR should be reopened. The engineering in `models/` would largely survive either way, since
the contact-episode contract and the open-cohort design are independent of the model engine.
