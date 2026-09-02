# ADR-0004: REST for ingest, GraphQL for query and admin

- **Status:** **Accepted**
- **Date:** 2026-09-02
- **Deciders:** Colubri (PI), mobile eng, backend eng
- **Implementation:** `contracts/api/ingest/v1.yaml`
- **Related:** ADR-0002 (observation envelope), ADR-0003 (single backend runtime)

## Context

The CAREER proposal specifies GraphQL for Module 1's API. The existing code does both, incompatibly:
Epigames uses REST with a generated OpenAPI Dart client (`epigames-app/api/o2_api`, from
`o2API.yaml`), while Travel Healthy uses GraphQL with Apollo (`th-backend/api/src/type-defs.ts`).
Two apps, two API styles, two client toolchains, two auth integrations, and no shared knowledge
between them. Resolving that fork is part of Aim 1, and it needs a rule rather than a preference.

The two things an Epidemica server is asked to do have almost nothing in common.

**Writing observations** happens on a phone, often from a background isolate, frequently offline,
in batches, over a network that may be metered or intermittent. The client needs to hand over bytes
and interpret the outcome with simple retry logic, and it must be able to re-send after an ambiguous
failure without creating duplicates. The shape of what it sends is fixed and known in advance.

**Reading data** happens in a browser, online, authenticated as a researcher, where the shape wanted
differs per screen: a console overview, an export builder, a cohort explorer, and a third-party
dashboard all want different projections of the same underlying rows.

A single API style has to compromise on one of these.

## Decision

We will split the planes.

| Plane | Style | Consumers |
|---|---|---|
| **Ingest** (device → server) | REST + OpenAPI 3.1 | Study apps, connectors, third-party uploaders |
| **Query and admin** | GraphQL (Absinthe) | Researcher console, exports, dashboards |

**Why REST for ingest.** Four reasons, in order of weight:

1. **Idempotency and partial success have a natural expression.** The ingest endpoint reports
   per-observation outcomes in a result body while using HTTP status codes for whole-request
   failures. GraphQL has no standard idempotency semantics, and its convention of returning `200`
   with an in-band `errors` array makes "did this land?" ambiguous — precisely the question a retry
   loop on a bad connection must answer unambiguously.
2. **The contracts are already JSON Schema, and OpenAPI 3.1 *is* JSON Schema 2020-12.** The ingest
   spec `$ref`s `contracts/observations/batch/1.0.0.json` directly. GraphQL SDL would require a
   second definition of every shape, maintained in parallel, free to drift — which is exactly the
   failure mode the contracts-first approach exists to prevent.
3. **HTTP semantics are the retry contract.** `429` with `Retry-After`, `503`, `Content-Encoding:
   gzip`, byte limits: all standard, all already understood by the reverse proxy, the load balancer
   and whoever operates the institution's deployment. None of it has to be invented or explained.
4. **Codegen is mature and multi-language.** OpenAPI generates the Dart client already in use, and
   gives a collaborator writing an uploader in Python or R a client for free.

**Why GraphQL for query and admin.** Variable query shape is the actual requirement, and the
alternative is endpoint proliferation (`/participants?include=…&expand=…&fields=…`). None of the
ingest constraints apply: it is read-mostly, online, and authenticated as a researcher. Travel
Healthy already uses GraphQL, so the skill exists, and Absinthe is mature in the Phoenix ecosystem
we are consolidating on.

## Consequences

**Positive.** Each plane gets the tool that fits it. The ingest contract is generated from the same
JSON Schema as everything else, so it cannot drift from the envelope. Retry and idempotency
semantics are unambiguous. Operators can reason about the ingest path with ordinary HTTP tooling,
including rate-limiting by path at the proxy. The existing REST/GraphQL fork is resolved by a
principle instead of a coin toss, and the proposal's GraphQL commitment is honoured where it earns
its keep.

**Negative, and this is the real cost.** Two API styles to build, document, secure and learn. Two
auth integrations, two error conventions, two bodies of documentation, and one more thing a
newcomer must absorb. Contributors will have to judge which plane a new capability belongs to, and
that boundary will be argued about. Some data is reachable both ways — an observation is written
over REST and read over GraphQL — so the two representations must be kept consistent by discipline
rather than by construction. And it deviates from the proposal text, which will need explaining to
reviewers and collaborators who read Aim 1.

**Neutral.** Third-party module authors get a documented write path without needing to learn
GraphQL, which lowers the barrier for the external contributions the platform is meant to attract.

## Alternatives considered

| Alternative | Why not |
|---|---|
| GraphQL for everything, as the proposal specifies | Mutations over an offline outbox have no idempotency key, in-band errors make retries ambiguous, batching is either aliased mutations or a non-standard transport extension, and every contract would need a parallel SDL definition alongside its JSON Schema. |
| REST for everything | The researcher console and exploratory access would need either endpoint proliferation or a bespoke query language. Forfeits the one place GraphQL genuinely wins, and Travel Healthy's existing GraphQL work with it. |
| gRPC for ingest | Better wire efficiency and excellent codegen, but harder to get through institutional proxies, no plain-`curl` debugging when a field site is failing, a poor browser story for the web-without-app channel, and another toolchain for a 2.5-person team. |
| A broker (MQTT, Kafka) for ingest | A real fit for continuous telemetry, but the pattern here is intermittent offline batches, not streaming, and it would add a component to a deployment ADR-0003 deliberately keeps to about four moving parts. |

## Open questions

None block this decision, but each needs an answer before the relevant component is built:

- **Server-originated observations.** The web instrument renderer and the CIAS/REDCap connectors run
  inside the server and produce observations without an HTTP round trip. Do they call the ingest
  endpoint over loopback, or write through an internal path? Either is defensible, but the resulting
  envelope must be byte-identical, and the answer should be recorded rather than improvised.
- **GraphQL schema evolution policy.** Deferred until the console work starts; GraphQL's deprecation
  model differs enough from ADR-0007's additive-within-a-major rule to deserve its own treatment.
- **Write access over GraphQL.** Current recommendation is never: one write path is a security
  property, not just a tidiness preference.

## Validation

The concrete test, checkable at any time: **adding a new observation type must require zero changes
to `contracts/api/ingest/v1.yaml`** — only a new payload contract. If a new module forces an API
revision, the ingest plane has absorbed something that belongs in the contracts, and the split is
not delivering what it promised.

Conversely, if within a year the team is routinely adding ingest-shaped endpoints to GraphQL or
query-shaped endpoints to REST, the boundary was drawn in the wrong place and this ADR should be
superseded rather than worked around.
