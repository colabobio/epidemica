# ADR-0014 — The participant state channel

**Status:** Accepted (2026-09-02)

## Context

Until now Epidemica has been one-directional. Observations flow up through the outbox; the only
thing that comes back is the protocol bundle, fetched once at enrolment. A device can tell the
server what happened, and the server can tell a device what to collect, but the server cannot tell a
device anything about the person carrying it.

M2 needs exactly that. A digital twin running on the server decides who is infected, and the app has
to show it. But the requirement is not specific to a game: an adherence study wants to show a
streak, a screening study a test result, a risk-communication study a score. Any study that gives
participants feedback needs a way for computed state to reach the device.

The obvious shortcut is a `GET /v1/game/state` returning the fields Epigames happens to need. That
would put one study's vocabulary into the platform, and the second study would add a second
endpoint.

## Decision

**A single downward channel, shaped as the mirror image of the observation envelope.**

| Going up | Coming down |
| --- | --- |
| `envelope_version` | `state_version` |
| `schema_uri` | `state_uri` |
| `payload` (opaque) | `state` (opaque) |
| `seq` (per-device monotonic) | `revision` (per-participant monotonic) |
| `observed_at` | `as_of` |

`GET /v1/participants/me/state` returns a document validated against
`contracts/state/participant_state/1.0.0.json`, whose `state` is validated separately against the
contract its `state_uri` names. `epidemica_core` parses the envelope, caches the document, and never
looks inside `state`.

Four properties are load-bearing:

**Scoped by token, not by path.** There is no parameter naming a participant, so one device cannot
ask about another even by guessing an identifier.

**`revision` is allocated by the database in the same statement that writes the state.** Read-then-
write would let two concurrent writers both see revision 4 and both write 5, after which a client
would treat a stale document as current.

**`as_of` is when the computation ran**, not when it was served or fetched. A study that recomputes
daily is a day stale by design, and an interface that cannot say so implies a liveness it does not
have.

**Core never manufactures a state document.** With nothing computed, the endpoint returns 404 and
the client holds null. An invented "you are healthy" is indistinguishable from a measured one, and a
participant acting on it would be acting on fiction.

## Consequences

**Positive.** Any study can give feedback without a new endpoint or a change to core. The server
validates state on the way out, so a malformed document is caught once rather than by every client
at once. An unknown `state_uri` passes through unvalidated by design — refusing it would make the
channel useless to precisely the studies it exists for, and it mirrors how an unknown `schema_uri`
is quarantined rather than rejected on the way in.

**Negative.** The platform is now bidirectional, which is a genuine increase in what the server
knows about how it is used. Previously a device revealed its data and learned nothing; now the
server maintains per-participant derived state. That state is still keyed by pseudonym and holds
nothing the participant did not generate, but it is a new category of thing to reason about in a
DPIA.

**Neutral.** Delivery is polled. A push variant (FCM waking a fetch) is an optimisation on top and
changes nothing here.

## Alternatives considered

**Study-specific endpoints.** Simplest for the first study and untenable by the third. Rejected for
the same reason ADR-0002 rejected per-module ingest paths.

**Extending the protocol bundle to carry state.** The bundle is per-study and immutable, identified
by a hash stamped on every observation. Making it per-participant and mutable would destroy that
property.

**Pushing state as an observation in reverse.** Observations are an append-only record of what
happened. Participant state is current, mutable and derived; conflating them would put derived data
into the immutable record.

## Validation

A study's state contract can change without any change to `epidemica_core`, and core contains no
identifier belonging to any particular study.
