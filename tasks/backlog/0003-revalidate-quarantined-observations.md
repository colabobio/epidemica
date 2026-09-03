# 0003 — Quarantined observations are never re-validated

**Status:** backlog
**Filed:** 2026-09-03
**Touches:** `server/lib/epidemica_server/contracts.ex` (docs), `server/lib/epidemica_server/ingest.ex`,
`server/lib/epidemica_server/projections.ex` (docs), a new `Ingest.revalidate/1`

## The problem

Two modules document a behaviour that does not exist.

`contracts.ex`:

> An observation this build cannot validate is stored with `validated: false` and **re-validated
> after the server is upgraded**, rather than …

`projections.ex`:

> … it is **picked up by a rebuild** after the schema arrives.

Neither happens. `validated` is written once, at ingest, and nothing ever revisits it. There is no
`update_all` touching it anywhere in `lib/`. A rebuild reads only `validated: true` rows, so a
quarantined observation is invisible to it by construction.

The consequence: an observation that arrived before the server knew its contract stays
`validated: false` for ever, and no projection will ever include it. Adding the schema afterwards
fixes nothing already collected.

## Why it matters

Quarantine exists precisely so that a client which outruns a server upgrade does not lose data. That
promise is half-kept: the bytes are safe, but they never become usable. For a study that collected
for a week before anyone noticed the schema was missing, "safe but permanently unusable" is not
meaningfully better than lost — the difference is only that it is recoverable *in principle*.

It is also the first thing a new module author will hit, since registering a contract with the server
is a step that is easy to do late. `docs/concepts/modules.md` now warns about this explicitly, which
is a documentation patch over a code gap.

## What is already in place

- Every quarantined row keeps everything needed to re-run the decision: the full `envelope` and
  `payload` maps, `schema_uri`, `envelope_version`, and `validation_reason`.
- `Contracts.validate_payload/2` and `validate_envelope/1` are pure functions of that data.
- `Ingest.validate/1` already encodes the whole decision; re-validation is the same call over stored
  rows rather than incoming envelopes.
- `Projections.rebuild_contacts/1` exists and would pick the rows up once they flip to validated.

## What needs doing

1. **`Ingest.revalidate/1`** — for a study, or globally: select `validated: false` observations whose
   `schema_uri` is now in `Contracts.known_payload_schemas/0`, re-run `validate/1` against the stored
   envelope, and update those that now pass. Rows that still fail keep their existing reason.

2. **Run it after a deploy.** Either an `EpidemicaServer.Release` entry called alongside `migrate`, or
   an Oban job. The migration hook is more predictable: schemas change only when the binary changes,
   so a deploy is exactly the moment the answer can differ.

3. **Then re-project.** `rebuild_contacts/1` for the affected study, or `project_contacts/1` which is
   already incremental and will pick up the newly validated rows on its own.

4. **Correct the two moduledocs** once it is true, or before then if this is not picked up.

## The design question worth settling first

Should re-validation be able to change `validated: true` back to `false`?

Tightening a contract in a new server version would mean previously accepted observations no longer
pass. Flipping them would silently remove data from projections that studies have already reported
on. Refusing to flip them means the store contains rows that the current contract would reject.

Neither is obviously right, and the choice should be deliberate. The instinct that matches the rest
of the codebase — ticks are immutable, settled days are never rewritten — is that **validation only
ever moves forward**, and a tightened contract is a new schema version rather than a redefinition of
an existing one. If that is adopted, say so in the moduledoc, because it is not self-evident.

## How it would be verified

- Ingest an observation whose schema is unknown to the build; assert it is quarantined with
  `:unknown_payload_schema`.
- Simulate the schema arriving, re-validate, and assert the row flips to `validated: true` with the
  reason cleared.
- Assert a projection then includes it — the end-to-end property that is currently broken.
- Assert a row that fails for a *different* reason (genuinely malformed payload) does **not** flip,
  and keeps its original reason.
- Assert re-validation is idempotent, and that it never touches already-validated rows.

Seeded defects worth confirming are caught: re-validating without checking the schema is now known;
clearing `validation_reason` on rows that still fail; flipping validated rows backwards.
