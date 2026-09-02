# The Observation Envelope

> **Status:** design accepted, not yet implemented. Decisions recorded in
> [ADR-0002](../adr/0002-observation-envelope.md). This document explains how the envelope is
> meant to be *used*; the ADR records *why* it exists.

## The one job it does

The envelope is the boundary between **"a module knows something about a participant"** and
**"the platform is responsible for getting that to the server, exactly once, with enough context to
interpret it years later."**

Everything a module knows goes in `payload`. Everything the *platform* knows — who, which study,
which protocol version, which device, when, in what order — goes in the envelope. A module never
sets envelope fields; core never inspects the payload.

```jsonc
{
  "envelope_version": "1.0",
  "study_id":        "uuid",
  "protocol_hash":   "sha256:…",   // exact study version that produced this
  "subject":         "pseudonym",   // client-generated; never PII
  "device_id":       "install-scoped uuid",
  "module":          "proximity",
  "schema_uri":      "https://schemas.epidemica.info/observations/proximity/contact_episode/1.0.0.json",
  "observed_at":     "2026-08-11T14:03:22.481Z",   // device clock, always UTC
  "clock_offset_ms": -1843,                         // measured against NTP; null if unknown
  "seq":             10427,                          // monotonic per device install
  "payload":         { /* validated separately against schema_uri */ }
}
```

**Wire shape vs. stored record.** The above is exactly what a client sends, and it is what
`contracts/observations/envelope/1.0.0.json` describes. Server-assigned fields — `received_at`,
`validated`, `validation_error` — are *absent* from that schema, and because it sets
`additionalProperties: false`, a client that tries to supply one is rejected. The rule "never
trusted from the client" is therefore enforced mechanically rather than by convention. The stored
record is the envelope plus those server fields.

## Where the schema is actually used

This surprises people: **the JSON Schema is not a runtime validator on the phone.**

| When | Where | What the schema does |
|---|---|---|
| Build time | `contracts/` → codegen | Generates Dart classes, Elixir structs, Python dataclasses. This is its main job. |
| CI | app and `models/` tests | Asserts anything the app can *construct* validates. Catches contract drift at PR time. |
| Runtime, server | Phoenix ingest | Validates on arrival. The actual enforcement point. |
| Export | `analysis/` | `schema_uri` → JSON Schema → JSON-LD → DCAT. This is how FAIR metadata is generated rather than hand-written. |

On-device you hold *generated types*, so a malformed observation is a compile error rather than a
runtime check. Validating JSON Schema on a phone for every proximity episode would burn battery
re-discovering what the type system already guarantees. Enable it in **debug builds only**, as a
canary for codegen bugs.

## Lifecycle of one observation

```mermaid
sequenceDiagram
    participant H as Herald (native)
    participant M as epidemica_proximity
    participant C as epidemica_core
    participant DB as Outbox (SQLite)
    participant S as epidemica_server
    participant PG as Postgres

    H->>M: RSSI samples via EventChannel
    M->>M: aggregate → ContactEpisode<br/>(bands, gaps, estimator version)
    M->>C: record(episode)
    C->>C: stamp study_id, subject, device_id,<br/>seq++, protocol_hash, clock_offset
    C->>DB: INSERT (durable before anything else)
    Note over DB: survives app kill and offline field sites
    C-->>M: returns immediately

    loop when connectivity allows
        C->>DB: SELECT unsent batch
        C->>S: POST /observations (gzip)
        S->>S: validate against schema_uri
        S->>PG: append; UNIQUE(device_id, seq) dedupes
        S-->>C: ack seq range
        C->>DB: mark sent
    end
    S->>PG: project → contacts, survey_responses, …
```

The property that matters: **`record()` is durable and synchronous; delivery is asynchronous.** A
module never waits on a network. That is what makes a two-week field study with no connectivity
work, and it is why the outbox write happens before anything else.

## What a module developer writes

The entire surface a module author touches:

```dart
// illustrative
await Epidemica.observations.record(
  ContactEpisodeObservation(
    peer: peerPseudonym,
    startedAt: start, endedAt: end,
    bandSeconds: bands,
    sampleCount: n, gapCount: gaps,
    estimator: 'coarse_distance', estimatorVersion: '2.0.0',
  ),
);
```

No HTTP, no retry, no JSON, no schema, no awareness that a server exists.

Compare with today. Adding a data type to Travel Healthy means touching a Hive model,
`hive_registrar.g.dart`, a GraphQL mutation, and `survey_data_sync_service.dart`. Adding one to
Epigames means extending `HistoryBaseModel` and the OpenAPI spec. Both collapse to "define a payload
schema, call `record()`."

## Who owns which field

This table is the design rationale, not just a description. It prevents a class of bugs by
construction: a module physically cannot mislabel a study or forge a timestamp.

| Field | Set by | Why it matters |
|---|---|---|
| `payload`, `schema_uri` | Module | The only things a module controls |
| `subject`, `device_id`, `study_id`, `protocol_hash` | Core | A module cannot mislabel or leak across studies |
| `seq` | Core | Monotonic per device; the basis of exactly-once |
| `observed_at`, `clock_offset_ms` | Core | Uniform clock discipline across every module |
| `received_at` | **Server only** | Never trusted from the client |

## Settled decisions

### Uniform per-observation shape, gzipped

Every observation carries a full envelope. No batch header, no per-item deltas.

A batch header would avoid repeating `study_id`, `device_id` and `protocol_hash` across a thousand
items, but request-level gzip already collapses that repetition, and server-side these fields are
normalised into real columns rather than stored per row. A uniform shape is simpler to generate,
simpler to validate, simpler to replay one record at a time, and simpler for a third party to
implement.

Clients set `Content-Encoding: gzip`; the server must accept both gzipped and plain bodies.

**Revisit only with measurement.** If a real deployment shows envelope overhead is material on
constrained networks, a batch header can be added as a compatible optimisation later. Do not
pre-optimise on the estimate.

### Unknown or invalid schema: accept, store, flag

The ingest endpoint never rejects an observation for schema reasons. It stores it, sets
`validated = false`, records the reason, and alerts.

The reason this matters: a newer app can outrun a server upgrade, and a field deployment is often
the *last* thing to be updated. Rejecting on unknown schema means a version lag silently destroys
data that can never be recollected. A quarantine is recoverable; a rejection is not.

Two distinct cases sit behind the same flag, and they need different handling:

| Case | Cause | Handling |
|---|---|---|
| **Unknown `schema_uri`** | Server older than app | Recoverable. Store, alert quietly. Re-validate and project after the server is upgraded. |
| **Known `schema_uri`, payload fails validation** | A real bug in app or contract | Not self-healing. Store, alert **loudly**, treat as a defect. |

Three consequences to build for:

- **Projections must skip unvalidated rows.** A projection assumes a known shape; feeding it
  unvalidated data corrupts the derived tables. Unvalidated observations stay in the append-only
  table only.
- **A backfill job is required**, not optional. After a schema is added or a bug fixed, re-validate
  the quarantined rows and project them. Without this, "accept and flag" is just a slower way of
  losing data.
- **Exports must surface the flag.** A dataset containing quarantined observations is not complete,
  and the completeness metric in `analysis/` must say so.

### `seq` does not reset per study

`seq` is monotonic per **device install**, for the life of that install, across every study the
device participates in. `(device_id, seq)` is the idempotency key and is globally unique.

Why: there is one outbox and one counter, so ordering and exactly-once delivery hold regardless of
how many studies a device is enrolled in. A per-study counter would need one outbox partition per
study and would break the guarantee whenever a participant joins a second study.

Practical notes:

- The counter is persisted in the outbox and allocated **inside the same transaction** as the row
  insert, so it survives app kills and background-isolate writes.
- On reinstall, `device_id` is new and `seq` restarts at 0. Uniqueness is on the pair, so this is
  fine — but it does mean a reinstall looks like a new device, which is the correct interpretation.
- **Footgun for analysts:** because the stream interleaves across studies, `max(seq)` is *not* the
  number of observations in a study, and gaps in `seq` within a study are expected and meaningful.
  Count rows; never infer counts from `seq`. This belongs in the researcher-facing data dictionary.

## Provisional defaults

Not yet ratified; these are the working answers until someone objects.

| Question | Working default |
|---|---|
| No NTP available | Record `clock_offset_ms: null` rather than assuming `0`. Analysis must distinguish "clock verified" from "clock unknown". |
| Withdrawal | Not an envelope concern. Handled by crypto-shredding the participant key (ADR-0008) and by the Contact Registry, not by a tombstone observation. |
| Tamper-evidence | Deferred, and cheap to defer. Because the schema policy is additive-within-a-major, an optional `signature` field can be added in any 1.x release. What *cannot* be retrofitted is a canonical serialisation rule, so that must be specified at the same time — and historical records stay unsigned regardless. |
| Oversize payloads | Open (ADR-0002). Interacts with the binary-attachment rule below. |

## What the envelope is *not* for

Worth stating plainly, because each of these will be attempted:

- **Not study configuration.** That flows server → app as the Study Protocol Bundle. The envelope is
  app → server only.
- **Not real-time game state.** Epigames peer state moves device-to-device over BLE and through
  Phoenix channels. Observations are the durable record, not the live wire.
- **Not binary blobs.** A lateral-flow photo does not belong in `payload` as base64. Upload it
  separately and put a content-addressed reference in the payload. Otherwise a 2 MB image lands in a
  JSONB column and the append-only table becomes unmanageable.

## An implementation constraint worth knowing early

The outbox must be writable **from background isolates**. Travel Healthy's headless geolocation task
and iOS BLE state restoration both produce observations at moments when the main isolate may not
exist.

Hive is not safe across isolates; SQLite in WAL mode is. This is the concrete reason behind the
"migrate off Hive" note in the roadmap — it is a correctness requirement the envelope design
imposes, not a preference.

## Validation in practice

`format` and `pattern` overlap in this schema, and **the pattern is normative.** JSON Schema's
format vocabulary is optional and unevenly supported: the Elixir server, the Dart client and the
Python tooling do not agree on which formats they check. Anything that must genuinely be enforced
— UTC-only timestamps, absolute `https` schema URIs, the pseudonym character class — is written as a
pattern, so it holds identically in every language. The `format` keywords remain as documentation
and as extra strictness where a validator happens to support them.

A related, concrete consequence of the licence policy: enabling Python's strict `uri` format checker
normally means installing `rfc3987`, which is **GPLv3+** and therefore excluded by the ADR-0009
allow-list. `rfc3339-validator` and `rfc3986-validator` (both MIT) cover `date-time` and `uri`
instead. This is the kind of thing the allow-list exists to catch.

## See also

- [ADR-0002 — Observation Envelope as the universal ingest contract](../adr/0002-observation-envelope.md)
- `contracts/observations/envelope/1.0.0.json` — the envelope contract
- `contracts/observations/batch/1.0.0.json` — the `POST /observations` request body
- `contracts/fixtures/observations/envelope/` — valid and invalid fixtures; the invalid ones are
  the part of the contract that actually constrains implementers
- `contracts/observations/proximity/contact_episode/1.0.0.json` — the first payload contract
