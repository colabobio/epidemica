# ADR-0001: Monorepo, package boundaries and app hosting

- **Status:** **Accepted**
- **Date:** 2026-09-02 (app hosting added the same day, while still Proposed)
- **Deciders:** Colubri (PI), mobile eng, backend eng

## Context

Epidemica spans four languages — Dart/Flutter (clients), Elixir (server), Python (models and
analysis), plus schema and deployment artifacts — and its central premise is that all of them
conform to shared contracts (see ADR-0002). The team is roughly 2.5 engineers.

The existing code is already fragmented across separate repositories (`epigames-app`,
`epigames-backend`, `th-app`, `th-backend`).

The dominant change pattern in Epidemica will be **a contract change that must land simultaneously
in a schema, a Dart client, an Elixir server, and a Python validator.** Whatever we choose must make
that a single reviewable, atomically revertable change.

## Decision

We will use **a single monorepo**, `epidemica/`, containing all platform code, contracts,
deployment artifacts and documentation.

Top-level boundaries:

| Path | Contents | Toolchain |
|---|---|---|
| `contracts/` | JSON Schemas, OpenAPI, GraphQL SDL, protocol bundle spec, cross-language fixtures | — (source of truth) |
| `packages/` | Dart/Flutter packages | pub workspace (`pubspec.yaml` at the repo root) |
| `server/` | Phoenix application | mix |
| `models/` | `starsim_epidemica` | uv / pytest |
| `analysis/` | validators, FAIR scoring, QA scripts | uv / pytest |
| `deploy/` | Compose stack, VM installer, runbook | — |
| `apps/` | Reference app binaries. An institution ships one of these, not one per study | flutter |
| `studies/` | Reference protocol bundles — study definitions containing no code | — |
| `docs/` | ADRs, specs, tutorials | — |

Rules:

1. **`contracts/` is the source of truth.** Generated clients are committed but never hand-edited,
   and CI fails if regeneration produces a diff.
2. **Dependencies point inward toward contracts, never sideways between modules.** A module may
   depend on `epidemica_core` and on contracts; it may not depend on another sibling module. This is
   what keeps modules independently adoptable.
3. **Directories are created when their first real file lands.** No empty scaffolding.
4. Packages are published to pub.dev/Hex/PyPI from the monorepo once stable; consumers are not
   required to vendor the whole repo.
5. **Apps consume packages only through their published public API.** No app may reach into a
   package's internals or rely on a monorepo-relative path, because an app outside this repository
   could not do either.

## App hosting and the three tiers

Building an Epidemica study should mostly not involve building an app. Three tiers of effort, and
the layout above follows from them:

| Tier | Who | What they do | What the platform must provide |
|---|---|---|---|
| **1 — no code** | Most studies | Author a protocol bundle, hand out a join code | A study-agnostic app binary and a way to author bundles |
| **2 — custom app** | Studies needing their own branding, store presence or extra screens | Copy the template, add the module packages they need, ship under their own developer account | Published packages and a template |
| **3 — new module** | Groups contributing a new data type | Write a package against the module interface plus a payload contract | A module interface and contract conventions |

**Tier 1 is the target for the common case, and it implies that an institution ships one app, not
one app per study.** The same binary runs any study whose modules it embeds; which study it is
running is decided by the join code and the protocol bundle fetched at enrollment. This is precisely
why `protocol_hash` is a required envelope field (ADR-0002): when the binary is generic, the bundle
is what makes a dataset reproducible.

It follows that **a Tier 1 study is not a directory of code — it is a protocol bundle.**
`studies/contactlog/` is the worked example: milestone M1 ships no study-specific Dart at all, and
the binary it runs on is `apps/template`.

### What counts as a module

The module set is what a binary can do, so it needs a definition rather than a convention. A module
is a Dart package that:

1. an app embeds **at build time** — which is why the module set is fixed per binary;
2. declares its own platform requirements: permissions, manifest entries, usage strings;
3. owns a **payload contract** in `contracts/`;
4. is **activated and configured at runtime by the protocol bundle**;
5. emits observations into `epidemica_core`'s outbox.

A module may span several packages — a federated plugin has a platform interface and per-platform
implementations — but it is one module because it satisfies those five properties once. Internal
layers are not modules: the proximity episode aggregator, for instance, has no contract, no platform
requirements and nothing a bundle could enable independently, so it lives inside
`epidemica_proximity` rather than beside it.

### Decision

- **Reference binaries live in `apps/`** in this repository, starting with `apps/template`. These
  are the dogfooding vehicles: a contract change breaks them in the same pull request that made it.
- **Reference protocol bundles live in `studies/`.** They double as documentation and as test
  fixtures. *Real* study bundles are authored in the researcher console and stored in the server
  database — they contain IRB numbers, join codes and consent text, and do not belong in a public
  repository. Nobody should ever open a pull request to add their study here.
- **External apps live in their own repositories** and depend on published packages.
- **No app is ever a fork of this monorepo.**

Forking is rejected firmly rather than merely discouraged. It would give every study a divergent
copy of the platform, make upstream fixes a permanent merge burden, and make "which version of the
platform produced this data" unanswerable — quietly undermining the reproducibility `protocol_hash`
exists to provide.

### Keeping the external path honest

The obvious failure mode of a monorepo is that the outside-in path rots unnoticed and the platform
ends up working only for the team that built it. One cheap CI job prevents it: copy `apps/template`
to a directory outside the workspace, resolve the Epidemica packages as git dependencies pinned to
the current commit, and build. If that job fails, a package has grown a monorepo-relative assumption
and Tier 2 is broken.

The trigger to publish to pub.dev and split out a standalone `epidemica-app-template` repository is
whichever comes first: the first external group wanting to build an app, or the start of Phase 2.

## Consequences

**Positive.** Contract changes are atomic and reviewable in one PR. There is exactly one CI
definition, one lint config, one version policy. Cross-language fixture tests (ADR-0012) are natural
rather than requiring a shared submodule. Newcomers read one repository.

**Negative.** CI must be path-filtered or it will run four toolchains on every commit — budget for
this early, it becomes painful around the 5-minute mark. Repository size grows with Flutter app
assets. Some collaborators will want only one package and will have to clone everything or wait for
published artifacts. Git history becomes noisier.

**The boundary of the Tier 1 promise.** "No code" holds only within the module set already compiled
into the binary a study runs on. Sensor modules contain platform code and cannot be added at
runtime, so an institution whose app lacks, say, the biosensing module needs a new build to run a
study that uses it. Tier 1 is therefore "no code *if the modules you need are already there*", and
it should be described that way rather than oversold. The practical consequence is that an
institution's app build should embed the modules it expects to need across its whole portfolio, not
just its first study.

**Neutral.** Release tagging needs a convention for per-package versions. The Dart side uses a
native pub workspace — one lockfile, one `.dart_tool`, no extra tool to install — which resolves
packages together but does not version or publish them; Elixir and Python need their own conventions
either way.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Polyrepo, one repo per module | The dominant change pattern is cross-cutting. Every contract change becomes a coordinated multi-repo dance with version-skew bugs. |
| Monorepo for contracts only, polyrepo for implementations | Keeps skew: nothing forces implementations to track the contract version. |
| Keep the existing separate repos and add contracts to one | Entrenches the current fragmentation and gives no home for `models/`, `deploy/` or `analysis/`. |
| One repository per study app | Multiplies the platform by the number of studies and makes every upstream fix a fan-out. It also encodes the assumption that a study needs an app, which Tier 1 exists to disprove. |
| A fork of the monorepo per study | Rejected above: divergent platform copies, permanent merge burden, and unanswerable provenance. |

## Open questions

- Do the existing repos get imported with history (`git subtree`) or start fresh with attribution?
  History is worth keeping for `epigames-app`; less so elsewhere.
- Public or private initially? ADR-0009 is now settled, so the remaining condition is a runnable
  example: **stay private until the Herald plugin extraction lands and `apps/template` builds.** A
  public repository with no runnable code is worse than none.
- Who publishes the app binary for a Tier 1 study — the institution, under its own developer
  account, or the project? This is a store-policy and support question as much as a technical one,
  and it needs an answer before the first external Tier 1 study, not before M1.

## Validation

If, six months in, contributors are routinely opening PRs that touch only one directory and
complaining about CI time, the boundaries were drawn too coarsely. If contract changes still require
more than one PR, the monorepo is not delivering its main benefit and something is wrong with rule 1.

For app hosting the test is sharper: **M1 must ship no study-specific Dart code.** If
`studies/contactlog` turns out to need a directory under `apps/` after all, then Tier 1 does not
work as described and the protocol bundle is not carrying enough — which would be worth knowing at
the first milestone rather than the fifth.
