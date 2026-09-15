# ADR-0003: Phoenix as the single backend runtime

- **Status:** Proposed
- **Date:** 2026-09-02
- **Deciders:** Colubri (PI), backend eng
- **Related:** Epigames-Migration-to-OSI.md (supersedes its Phase 1 framing)

## Context

Two backends currently serve equivalent API contract:

- **`epigames-backend/opout-api`** — Go on AWS Lambda, deployed with the Serverless Framework,
  fronted by API Gateway with shared API keys, using RDS PostgreSQL, Cognito and Secrets Manager.
  Endpoints include `/simulation?code=`, `/participants`, `/history`, `/participants/qrcodes`.
- **`th-backend`** — Apollo GraphQL on Aurora with Cognito.

The CAREER proposal (Aim 1, Module 7) anticipates *switching between* a stateful Phoenix backend and
serverless Lambda depending on whether a study is low-latency/high-concurrency or
high-latency/low-concurrency.

Two constraints make that untenable. First, the team is roughly 2.5 engineers; two production
runtimes means two deployment paths, two auth models, two migration stories and two on-call
surfaces. Second, and decisively: **AWS Lambda cannot be self-hosted.** Institutional deployment by
Leibniz — and GDPR data residency generally — is a primary goal, and a serverless component makes it
unreachable.

## Decision

We will **consolidate on Phoenix/Elixir as the single backend runtime** into `epidemica_server`, and **retire the Go/Lambda backend** on a published sunset date.

We will *not* implement the proposal's dual-runtime switching. Background and batch work uses
**Oban** (Postgres-backed) rather than a second compute model — this replaces the
`dispatchActiveSimulations` / `processSimulation` Lambda pair directly.

The reference deployment is Phoenix + PostgreSQL + Caddy on a single VM. Kubernetes (k3s) is an
optional second target for multi-site scale, never the reference.

## Consequences

**Positive.** One runtime, one deployment story, one auth model. Self-hosting becomes possible,
which unblocks Leibniz and every EU-residency requirement. Realtime simulation state stays in
GenServers and PubSub rather than being reconstructed from polling. The LiveView console already
exists, so the researcher UI and the web-instrument renderer (§6.2 of the roadmap) come nearly free
— the latter is what enables participation without an app. Operational surface drops from roughly
eight AWS services to about four components.

**Negative.** Elixir has a smaller hiring pool than Go or Python; the grad-student backend role
becomes harder to fill and slower to onboard. We lose scale-to-zero — an idle study now costs a
running VM (realistically tens of dollars per month, against the portability gain). Vertical scaling
has a ceiling that Lambda does not; a single very large deployment may need k3s sooner than
otherwise. Migrating the Epigames production dataset off RDS/Lambda is real, non-trivial work with a
dual-run period.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Keep both, per the proposal | 2× maintenance for a 2.5-person team, and it forfeits self-hosting entirely. |
| Containerise the Go Lambdas and orchestrate them (the current OSI migration draft) | Preserves a decomposition that only existed to fit Lambda, and imports ~9 replacement services (Traefik, Keycloak, Vault, SeaweedFS, Prometheus…) into an institution that must operate them. |
| Consolidate on Go instead | No experience with Elixir. |
| Rewrite in Python (aligning with `models/`) | Would align with Starsim, but concedes the realtime and admin-UI advantages and is a from-scratch rewrite of a working system. |

## Open questions

- **Sunset date for the Go/Lambda API**, to be published in Phase 0 so collaborators can plan.
- Data migration approach for the live Epigames dataset: dual-write, or export/import with a freeze
  window?
- Does Leibniz have an existing Keycloak or institutional OIDC to adapt to, rather than us shipping
  one?

## Validation

The dual-run for the first migrated Epigames deployment must produce **row-for-row identical
exports** from both backends. If it does not, we do not cut over.
