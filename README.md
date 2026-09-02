# Epidemica

Modular infrastructure for building mobile apps that collect high-resolution, multi-modal
epidemiological data and deliver interventions.

> **Status: pre-alpha.** Nothing here is usable yet. The repository currently contains architecture
> decision records only. See [`docs/adr/`](docs/adr/) and the
> [architecture and roadmap](../proposal/Epidemica-Architecture-and-Roadmap.md).

## What this is

Epidemica is a set of **contracts** — data schemas and protocols — plus reference implementations of
those contracts for mobile clients, a server, and analysis tooling. Researchers assemble study
apps from Epidemica modules rather than building data collection infrastructure from scratch.

The platform is designed so that a study can run over **any channel**: a mobile app, SMS, voice,
plain mobile web, or staff-mediated contact. Only the sensor modules require an installed app.

## Planned layout

Directories appear as their first real content lands. Empty scaffolding is deliberately avoided.

| Path | Contents | Status |
|---|---|---|
| `contracts/` | JSON Schemas, OpenAPI, GraphQL SDL, protocol bundle spec, test fixtures | **started** — envelope, batch, `contact_episode`, `location_fix`, `survey_response` |
| `packages/` | Dart/Flutter packages (melos workspace) | not started |
| `server/` | Phoenix application, incl. `epidemica_reach` and the contact registry | not started |
| `models/` | `starsim_epidemica`: Starsim network/disease modules and protocol loader | **started** — spike complete |
| `analysis/` | Python: contract validation, FAIR scoring, data-quality scripts | **started** — contract test suite |
| `deploy/` | Docker Compose stack, single-VM installer, operator runbook | not started |
| `apps/` | `epigames/`, `travelhealthy/`, `template/` — thin study apps | not started |
| `docs/` | ADRs, module specs, tutorials, study cookbook | **started** |

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