# Epidemica

Modular infrastructure for building mobile apps that collect high-resolution, multi-modal
epidemiological data and deliver interventions.

> **Status: alpha.** The full arc — join, sense, upload, ingest, reconcile, simulate, settle,
> publish — runs end to end, and has been field-tested on real devices with two study types.
> **Not yet suitable for unattended data collection:** ticks are run by hand
> ([task 0002](tasks/backlog/0002-scheduled-ticks.md)). Background sync is now in place
> ([task 0006](tasks/done/0006-no-background-sync.md)), but not yet verified on physical devices.

## What this is

Epidemica is a set of **contracts** — data schemas and protocols — plus reference implementations of
those contracts for mobile clients, a server, and analysis tooling. Researchers assemble study
apps from Epidemica modules rather than building data collection infrastructure from scratch.

The platform is designed so that a study can run over **any channel**: a mobile app, SMS, voice,
plain mobile web, or staff-mediated contact. Only the sensor modules require an installed app.

## Layout

Directories appear as their first real content lands. Empty scaffolding is deliberately avoided.

| Path | Contents | Status |
|---|---|---|
| `contracts/` | JSON Schemas, OpenAPI, protocol bundle spec, test fixtures | **built** — 12 contracts, fixture-driven suite |
| `packages/` | Dart/Flutter packages (native pub workspace) | **built** — core, proximity (federated), survey |
| `server/` | Phoenix application, incl. `epidemica_reach` and the contact registry | **built** — ingest, projections, twin runtime, scoring, state channel. Reach and registry not started |
| `models/` | `starsim_epidemica`: Starsim network/disease modules and protocol loader | **built** — twin tick, network bridge, network export |
| `analysis/` | Python: contract validation, FAIR scoring, data-quality scripts | **started** — contract test suite, network visualiser |
| `deploy/` | Docker Compose stack, single-VM installer, operator runbook | **started** — local dev stack only |
| `apps/` | Reference app binaries. An institution ships one, not one per study | **built** — `template`, `epigames` |
| `studies/` | Reference protocol bundles — study definitions containing no code | **built** — `contactlog`, `epigame7`, `epigame-debug` |
| `docs/` | ADRs, concepts, milestones, tutorials | **started** — tutorials not written |
| `tasks/` | Known work, filed with the investigation already done | **built** |
| `tools/` | Development-only scripts, not part of any shipped runtime | **started** — [license scan](tools/README.md) |

## Architecture decisions

All significant decisions are recorded in [`docs/adr/`](docs/adr/). Read
[the index](docs/adr/README.md) first.

No decision currently blocks engineering work. The outstanding validation item is **Spike B** in
[ADR-0012](docs/adr/0012-starsim-as-canonical-transmission-model.md): the Starsim bridge has been
validated against synthetic data only, so no scientific claim should rest on it until it has been
checked against a real deployment export.

## Concepts

Explanations of how the platform works, as opposed to why decisions were made:

- [The Observation Envelope](docs/concepts/observation-envelope.md) — how every module's data
  reaches the server, exactly once, with enough context to interpret it years later.
- [Modules](docs/concepts/modules.md) — the boundary a module implements, and what it is handed.
- [The server](docs/concepts/server.md) — ingest, projections, and what is derived from what.
- [Building a study](docs/concepts/building-a-study.md) — authoring a protocol bundle.
- [Proximity](docs/concepts/proximity.md) — BLE sensing, episodes, and reconciliation.
- [Background sync](docs/concepts/background-sync.md) — how observations leave the device when
  nobody is looking at the screen, and why that differs by platform.
- [The state channel](docs/concepts/state-channel.md) — how conclusions reach a participant.
- [Surveys](docs/concepts/surveys.md) — scheduled instruments and how they are delivered.
- [Epigame](docs/concepts/epigame.md) — the transmission game built on all of the above.
- [Arms](docs/concepts/arms.md) — randomised assignment and per-arm rules.
- [Licensing](docs/concepts/licensing.md) — what governs your own app or module if you build on
  this, and what the automated license scan protects against.
- [AI-assisted coding](docs/concepts/ai-assisted-coding.md) — accepted practice for working with a
  coding agent here, and what this platform specifically asks of you.

## Milestones

- [M1 — Contact logging end to end](docs/milestones/m1-contact-logging.md) — the first vertical
  slice through every layer: contract, module, core, server, analysis.
- [M2 — Epigames as a digital twin](docs/milestones/m2-epigames.md) — a Starsim simulation driven by
  the contact network participants produce.

## Contracts

| Contract | What it defines |
|---|---|
| `contracts/observations/envelope/1.0.0.json` | The wrapper every observation travels in |
| `contracts/observations/batch/1.0.0.json` | The `POST /observations` request body |
| `contracts/observations/proximity/contact_episode/1.0.0.json` | Bluetooth proximity episodes |
| `contracts/observations/location/location_fix/1.0.0.json` | Geographic position, with explicit minimisation |
| `contracts/observations/instruments/survey_response/1.0.0.json` | Instrument responses from any channel |
| `contracts/observations/health/module_status/1.0.0.json` | A module's positive claim that it was collecting |
| `contracts/instruments/definition/1.0.0.json` | Instrument items, versioned independently of the bundle |
| `contracts/bundle/1.0.0.json` | The protocol bundle: a study definition containing no code |
| `contracts/state/participant_state/1.0.0.json` | The document the server publishes to one participant |
| `contracts/state/epigame/1.0.0.json` | The Epigames-specific participant state |
| `contracts/wire/proximity_payload/1.0.0.md` | The bytes broadcast over BLE |
| `contracts/api/ingest/v1.yaml` | The device-facing ingest API (OpenAPI 3.1) |

All of it is exercised by the fixture-driven suite in [`analysis/`](analysis/README.md).

> The ingest spec still assumes one decision whose ADR is not yet written: **ADR-0005** (participant
> tokens replacing shared API keys). The spec sketches a bearer-token scheme but deliberately leaves
> token lifetime and rotation policy open; it is the de facto record until that ADR is drafted.

## License

Code is licensed under the **Apache License 2.0** — see [`LICENSE`](LICENSE) and
[`NOTICE`](NOTICE). Documentation, schemas and specifications are licensed under **CC-BY-4.0**.
See [ADR-0009](docs/adr/0009-open-source-license.md) for the reasoning.

New source files carry an SPDX header:

```
// SPDX-License-Identifier: Apache-2.0
```

> **CIAS boundary policy.** CIAS 3.0 is GPL-3.0. Epidemica integrates with it **only across a
> network boundary**. No CIAS-derived code may enter this repository.