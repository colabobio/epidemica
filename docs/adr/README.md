# Architecture Decision Records

An ADR records a decision that is **expensive to reverse**, together with the reasoning and the
alternatives that were rejected. Its value is mostly to whoever inherits the codebase and asks
"why on earth is it done this way?" — including future us.

## Conventions

- One decision per record. If you need "and", it is probably two ADRs.
- One page. If it does not fit, the decision is not yet clear enough to record.
- Immutable once **Accepted**. To change a decision, write a new ADR that supersedes the old one and
  edit the old one's status to `Superseded by ADR-XXXX`. Never rewrite history.
- Use [`0000-template.md`](0000-template.md).

## Statuses

| Status | Meaning |
|---|---|
| `Proposed` | Drafted, not yet agreed. **Do not build on it.** |
| `Accepted` | Agreed. Code may depend on it. |
| `Superseded by ADR-XXXX` | Replaced. Kept for the historical record. |
| `Rejected` | Considered and declined. Kept so it is not relitigated. |

## Index

| # | Title | Status |
|---|---|---|
| [0001](0001-monorepo-and-package-boundaries.md) | Monorepo, package boundaries and app hosting | **Accepted** |
| [0002](0002-observation-envelope.md) | Observation Envelope as the universal ingest contract | **Accepted** |
| [0003](0003-single-backend-runtime.md) | Phoenix as the single backend runtime | Proposed |
| [0004](0004-rest-for-ingest-graphql-for-query.md) | REST for ingest, GraphQL for query and admin | **Accepted** |
| [0009](0009-open-source-license.md) | Open-source license selection | **Accepted** — Apache-2.0 |
| [0012](0012-starsim-as-canonical-transmission-model.md) | Starsim as the canonical transmission model | **Accepted** — Spike A passed |

## Planned, not yet drafted

These are deliberately deferred because they depend on decisions above. Drafting them now would
mean rewriting them.

| # | Title | Blocked by |
|---|---|---|
| 0005 | Participant tokens replace shared API keys | 0003 |
| 0006 | Study Protocol Bundle format and versioning | 0002 |
| 0007 | Schema evolution policy | 0002 |
| 0008 | Privacy architecture: pseudonymity, key management, BLE payload strategies | 0002 |
| 0010 | Module Definition of Done and the dogfooding gate | 0001 |
| 0011 | Contact Registry separation and per-channel consent | 0002, 0003, 0008 |
| 0013 | Division of labour between Starsim, Opqua and GAMA | 0012 |
