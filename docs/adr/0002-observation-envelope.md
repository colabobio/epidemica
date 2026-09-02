# ADR-0002: Observation Envelope as the universal ingest contract

- **Status:** Proposed
- **Date:** 2026-09-02
- **Deciders:** Colubri (PI), mobile eng, backend eng

## Context

Epidemica must ingest heterogeneous data — Bluetooth contact episodes, GPS fixes, survey responses,
symptom reports, infection events, in-app actions, lateral-flow results, air-quality readings, and
message delivery receipts — from intermittently connected devices, and later from SMS, voice and
web channels that are not devices at all.

The two existing apps each solved this separately and incompatibly:

- Epigames posts batches to `/history` as `HistoryBaseModel` (`{time, type, …}`) via a generated
  OpenAPI client, with **no idempotency key** — a retry after a flaky upload can duplicate rows.
- Travel Healthy stores `SurveyHive` objects in Hive and syncs them through bespoke GraphQL
  mutations in a background isolate (`survey_data_sync_service.dart`).

Consequently every new data type costs work in three places, and neither app can answer "which
version of the study produced this row?" — which Aim 2's validation work and any IRB audit require.

## Decision

We will define **one envelope** that every observation from every module and every channel conforms
to, and **one ingest endpoint** that accepts batches of them.

```jsonc
{
  "envelope_version": "1.0",
  "study_id":        "uuid",
  "protocol_hash":   "sha256:…",   // exact study version that produced this
  "subject":         "pseudonym",   // never PII
  "device_id":       "install-scoped uuid",
  "module":          "proximity",
  "schema_uri":      "https://schemas.epidemica.info/proximity/contact/1.2.0",
  "observed_at":     "2026-08-11T14:03:22.481Z",
  "clock_offset_ms": -1843,         // device clock vs. NTP, measured
  "received_at":     "…",           // server-stamped, never client-supplied
  "seq":             10427,         // per-device monotonic
  "idempotency_key": "device_id:seq",
  "payload":         { }            // validated against schema_uri
}
```

Consequent rules:

1. **`epidemica_core` owns the outbox.** A module contributes a schema and a payload builder and
   nothing else — no networking, no retry logic, no persistence.
2. **Storage is append-only.** `observations` partitioned by `(study_id, month)`, `payload` as
   `JSONB`, unique constraint on `(device_id, seq)`.
3. **Projections are derived.** Module tables (`contacts`, `survey_responses`, …) are materialised
   from observations and are always rebuildable. Nothing writes to a projection directly.
4. **`schema_uri` is immutable and resolvable.** It dereferences to the JSON Schema plus a JSON-LD
   context, which is what makes FAIR/DCAT export a build step rather than a research project.
5. Server-controlled fields (`received_at`, `study_id` binding) are never trusted from the client.

## Consequences

**Positive.** One sync engine, one offline queue, one retry policy for the entire platform. Retries
become safe by construction. A third party can add a module without touching transport code — which
is the precondition for the "others contribute modules" goal. Provenance (`protocol_hash`) and clock
integrity (`clock_offset_ms`) are recorded per row, which Aim 2 needs and which no current app
captures. Crypto-shredding for GDPR erasure has a single place to act.

**Negative.** `JSONB` plus projections is more machinery than direct table writes, and projection
rebuild logic must be maintained and tested. Schema versioning discipline becomes mandatory — a
sloppy `schema_uri` bump silently forks a dataset. Append-only storage grows monotonically and needs
a partition/retention strategy from day one, not later. Query performance for analytics depends
entirely on the projections being right.

**Neutral.** Envelope overhead is roughly 250–300 bytes per observation; negligible for surveys,
non-trivial for high-frequency proximity data — which is a further argument for uploading
`contact_episode` aggregates rather than raw RSSI (see ADR-0008, planned).

## Alternatives considered

| Alternative | Why not |
|---|---|
| Per-module endpoints and tables (status quo) | Every module re-implements sync, retry and offline behaviour. This is the current cost we are trying to remove. |
| Generic key–value event log, untyped payloads | Loses validation and FAIR metadata; datasets become un-analysable without tribal knowledge. |
| A message broker (Kafka/NATS) as the ingest bus | Real operational weight for a single-VM, self-hosted research deployment. Postgres is sufficient at the scale evidenced so far (~4,000 concurrent users) and is already a required dependency. |
| CDISC ODM or FHIR as the native wire format | Both are export targets, not ingest formats — too heavy for a mobile outbox, and neither models Bluetooth contact episodes naturally. Map at export instead. |

## Open questions

- Payload size cap and behaviour on oversize observations (reject vs. spill to object storage).
- Whether `subject` rotates per study or is stable across studies at one institution — this
  interacts with ADR-0011.
- Retention default: the roadmap proposes `raw_ttl_days: 730`, which needs an IRB sanity check.

## Validation

Adding the second module (instruments) after the first (proximity) should require **zero** changes
to `epidemica_core`'s sync code. If it does not, the envelope is under-specified and we should stop
and fix it before a third module lands.
