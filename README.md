<p align="center">
  <img src="assets/epidemica-wordmark.png" alt="Project Logo" width="200"/>
</p>

Epidemica is a modular infrastructure for building mobile apps that collect high-resolution, multi-modal
epidemiological data and deliver interventions.

For an introduction presentation to Epidemica in pdf format, follow [this link](docs/presentations/Epidemica-Platform-Intro-Sep-22-2026.pdf). A preprint is also 
currently available on [GenRxiv](https://genrxiv.org/article/ark:99999/genrxiv-2026-00002).

> **Status: Alpha.** Initial testing has been done on local deployments of server/apps. See the architecture
> decision records in [`docs/adr/`](docs/adr/) and the
> [architecture and roadmap](docs/architecture-and-roadmap.md).

## What this is

Epidemica is a set of **contracts** — data schemas and protocols — plus reference implementations of
those contracts for mobile clients, a server, and analysis tooling. Researchers assemble study
apps from Epidemica modules rather than building data collection infrastructure from scratch.

The platform is designed so that a study can run over **any channel**: a mobile app, SMS, voice, or
plain mobile web. Only the sensor modules require an installed app.

## Note from Epidemica's author

This initial implementation relied on substantial use of generative AI (Claude Opus 5 model) during August and 
September of 2026. However, the concept for Epidemica goes back to 2024, inspired by my work in the [Operation 
Outbreak](https://colabobio.medium.com/226ca7bd90d8), [Travel Healthy](https://colabobio.medium.com/cf2148ecd6e2), 
and [Epigames](https://colabobio.medium.com/f895b363c846) projects, which prompted me to consider the need of a 
common open-source infrastructure for digital epidemiology research. This concept took more concrete shape in a 
proposal I submitted in 2025 for an NSF CAREER award (not funded), which is fully available [here](docs/background/Epidemica-NSF-CAREER-full-proposal-2025.pdf). 

Not being a software engineer myself and funding constrains faced by my lab since last year, posed a significant 
barrier for the development of Epidemica. However, curiosity in the recent progress in AI-assisted coding let me to 
explore the use of the latest frontier models in mid-2026 to refine the concept I put forward in the CAREER proposal 
into an actual architecture specification, and then to actually implement it. The output of these explorations resulted 
in the framework available in this repository, which I have partially reviewed and tested (process is currently ongoing). 
One the one hand, it's easy to feel amazed by the incredible capacity of large language models and agentic systems to 
generate complex software such as Epidemica, provided the appropriate context and supervision. 
On the other hand, we are only starting to grasp the impacts of this new technology across multiple domains of human activity, 
both positive and negative. I'm not immune to questions and uncertainties presented by the rapid advance of generative AI,
and I consider Epidemica my own way to explore how AI-assisted coding can be meaningfully incorporated into existing 
development practices when it is appropriate to do so, while balancing it costs and benefits.

For now, I decided that the best course of action would be to release Epidemica in its current form as open source under
Apache 2.0 license, to facilitate deeper examination by the digital epidemiology community, and potentially be useful in other
projects, as it was its original motivation. My immediate goal after the initial AI-assisted development push is to complete
the review of the code and documentation and continue to build on top of it to advance the research in my lab. 

## Current layout

Directories appear as their first real content lands. Empty scaffolding is deliberately avoided.

| Path | Contents | Status |
|---|---|---|
| `analysis/` | Contract validation, data-quality checks and FAIR tooling for Epidemica datasets | test suite and epigame's netviz implemented |
| `apps/` | Reference app projects | **started** — template and epigames apps |
| `contracts/` | JSON Schemas binding Elixir server, Dart clients and Python analyses | ingest API, study bundle, instruments, observations, state  |
| `deploy/` | Scripts for local deployment, Docker Compose stack, single-VM installer, operator runbook | **started** — local scripts tested |
| `docs/` | Architecture and roadmap, ADRs, concepts, manuscript, milestones, tutorials | **ongoing** - updated as new features as implemented |
| `models/` | `starsim_epidemica`: Starsim network/disease modules and protocol loader | **started** — spike complete |
| `packages/` | Dart/Flutter packages (melos workspace) | core, proximity, and survey modules available |
| `server/` | Phoenix application, incl. study registry, enrollment, observation ingest, and derived projections | tested locally |
| `studies/` | Reference protocol bundles — study definitions containing no code | implemented contactlog, epigame-debug, and epigame7 |
| `tasks/` | Work that is active, in the backlog, or done | implemented contactlog, epigame-debug, and epigame7 |
| `tools/` | Scripts for open-source provenance, license audit, and LLM transcript  |

## Architecture decisions

The Architecture and Roadmap document is provided in [`docs/architecture-and-roadmap.md`](docs/architecture-and-roadmap.md), 
while Technical Invariants from code audit in [`docs/technical-invariants.md`](docs/technical-invariants.md)

All significant decisions are recorded in [`docs/adr/`](docs/adr/). Read
[the index](docs/adr/README.md) first.

## Concepts

A collection of documents explaining how different aspects of the platform work:

- [AI-assisted coding](docs/concepts/ai-assisted-coding.md) - practical recommendations on the use of AI coding agents to contribute to Epidemica or build Epidemica-based tools.
- [Background sync](docs/concepts/background-sync.md) — how observations leave the device irrespective of app's status, why that differs by platform, and what it does not yet solve.
- [Building a study](docs/concepts/building-a-study.md) - detailed guide explaining how to assemble a study using the different pieces offered by Epidemica.
- [Epidemica licensing](docs/concepts/epidemica-licensing.md) - license governing what in this repository, rationale behind it, and implications for Epidemica-based tools.
- [Epidemica modules](docs/concepts/epidemica-modules.md) - what an Epidemica module is, how they are registered, activated, and added to a study.
- [Epigames guide](docs/concepts/epigames-guide.md) - 
- [The Observation Envelope](docs/concepts/observation-envelope.md) — how every module's data reaches the server exactly once, with enough context to interpret it after the study has concluded.
- [Proximity sensing](docs/concepts/proximity-sensing.md) - a document explaning the architecture of the included Epigames app for conducting epidemic game studies.
- [Study arms](docs/concepts/study-arms.md) - guide on how to run an epigame as a randomized experiment mith multiple arms (simple weighted, not block ranomization).
- [Study server](docs/concepts/study-server.md) - introduction to the Phoenix server application and PostgreSQL database behind Epidemica-based study apps.
- [Survey instruments](docs/concepts/survey-instruments.md)  - how to create survey instruments to deliver to study participants using Epidemica's survey module.

## Milestones

- [M1 — Contact logging end to end](docs/milestones/m1-contact-logging.md) — the first complete demo app
  using every layer in Epidemica: contract, module, core, server, analysis.
- [M2 — Epigames as a digital twin](docs/milestones/m2-epigames.md)

## Contracts

| Contract | What it defines |
|---|---|
| `contracts/api/ingest/v1.yaml` | The device-facing ingest API (OpenAPI 3.1) |
| `contracts/bundle/1.0.0.json` | The document that turns a generic Epidemica binary into a specific study |
| `contracts/fixtures` | This directory contains contract test fixtures used for schema and validation testing (positive/negative) |
| `contracts/game/epigame_rules/1.0.0.vectors.json` | Shared test vectors for the epigame scoring rules |
| `contracts/instruments/definition/1.0.0.json` | Shared test vectors for the epigame scoring rules |
| `contracts/observations/batch/1.0.0.json` | The `POST /observations` request body |
| `contracts/observations/envelope/1.0.0.json` | The wrapper every observation travels in |
| `contracts/observations/health/module_status/1.0.0.json` | A claim that a module was, or was not, collecting during a stated window |
| `contracts/observations/instruments/survey_response/1.0.0.json` | Instrument responses from any channel |
| `contracts/observations/location/location_fix/1.0.0.json` | Geographic position, with explicit minimisation |
| `contracts/observations/proximity/contact_episode/1.0.0.json` | Bluetooth proximity episodes |
| `contracts/state/epigame/1.0.0.json` | What a player is told about their own game, carried as the `state` of a participant state document |
| `contracts/state/participant_state/1.0.0.json` | What the server tells a device about its own participant |
| `contracts/wire/proximity_payload` | Proximity BLE payload |

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