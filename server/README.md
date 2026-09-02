# epidemica_server

The Epidemica backend: study registry, enrollment, observation ingest, and derived projections.
Implements `contracts/api/ingest/v1.yaml`.

Status: **in progress** (milestone W4). The ingest core and contract validation work and are tested;
the HTTP layer, enrollment and the contacts projection are not yet built.

## Setup

Requires Elixir 1.18+, Erlang/OTP 27+, and PostgreSQL 14+.

```bash
mix deps.get
mix ecto.setup        # create + migrate
mix test
```

Database credentials are read from the standard libpq environment variables (`PGUSER`, `PGPASSWORD`,
`PGHOST`), falling back to the OS user. Nobody should have to edit tracked config to run the tests.

## Contract validation

`EpidemicaServer.Contracts` compiles the schemas in `contracts/` into Elixir functions at build
time, via [exonerate](https://github.com/E-xyza/Exonerate).

This means **the release can only validate schemas it was built with**. That is not a limitation to
work around — it is the ingest design in ADR-0002. An observation whose `schema_uri` this build does
not know is stored with `validated: false` and re-validated after an upgrade, rather than rejected
and lost. Editing a schema file triggers recompilation, via `@external_resource`.

`test/epidemica_server/contracts_test.exs` runs the *same* fixtures as
`analysis/tests/test_contracts.py` and requires identical accept/reject decisions on all 65. A
contract meaning one thing in Dart and another in Elixir would produce a client and a server that
disagree in the field; this test is what prevents that.

### Dependency note: exonerate and decimal

Exonerate 1.2.2 declares `decimal ~> 2.0` while Ecto 3.14 requires `decimal ~> 3.0`. The two cannot
be resolved together, so `mix.exs` carries:

```elixir
{:decimal, "~> 3.0", override: true}
```

The override is safe *for our contracts*, and that claim is empirical rather than hopeful: exonerate
uses Decimal for `multipleOf` on numeric types, which none of our schemas use, and the cross-language
fixture suite confirms every contract still validates identically in both languages. Re-check this if
a future contract introduces `multipleOf` — noting that exonerate does not support it for numbers
anyway.

## Ingest behaviour

| Outcome | Meaning | Stored? |
|---|---|---|
| `accepted` | Envelope and payload both validated | Yes, `validated: true` |
| `duplicate` | `(device_id, seq)` already held | Already present; nothing written |
| `quarantined` | Identifiable but not validatable | Yes, `validated: false`, with a reason |
| `rejected` | `(device_id, seq)` unusable, so there is no key to store it under | No |

Quarantine reasons separate a recoverable version lag (`unknown_envelope_version`,
`unknown_payload_schema`) from a contract defect (`envelope_invalid`, `payload_invalid`). The first
pair re-validates after a deploy; the second will not fix itself and should alert loudly.

A batch is homogeneous and must match its token. One that disagrees is refused outright rather than
partially accepted, because accepting it would let one device write observations attributed to
another participant.

## Still to build for W4

- HTTP layer: router, controllers, participant-token plug, gzip request bodies
- Enrollment and token issuance
- The `contacts` projection and its rebuild path
- Release configuration and a bare-VM deployment check

## Phoenix

  * Start with `mix phx.server`, or inside IEx with `iex -S mix phx.server`
  * Guides: https://hexdocs.pm/phoenix/overview.html
