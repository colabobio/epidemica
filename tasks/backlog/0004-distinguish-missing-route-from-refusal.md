# 0004 — A missing route and a refused request look the same to the client

**Status:** backlog
**Filed:** 2026-09-03
**Touches:** `packages/epidemica_core/lib/src/enrollment.dart`, `tokens.dart`,
`sync/ingest_client.dart`, `state/state_channel.dart`

## The problem

The client maps HTTP status codes to meanings without looking at what the server actually said:

```dart
return switch (response.statusCode) {
  201 => response,
  404 => throw const EnrollmentException(
    EnrollmentFailure.unknownJoinCode,
    'no open study matches that code',
  ),
  ...
};
```

A 404 has two entirely different causes here. The server can be *saying no* — no open study matches
that join code — or the request can never have reached a route at all, because the base URL was
wrong. The second is reported to the participant as the first: **"That code did not match an open
study."**

That is a configuration mistake wearing a data mistake's clothes, and it sends whoever is debugging
to inspect join codes, study status and schedules, all of which are fine.

## How it showed up

A device was launched with `EPIDEMICA_SERVER=http://host:4000/v1` — no trailing slash. `Uri.resolve`
treats a base without one as naming a file and replaces the last segment:

```
http://host:4000/v1   + enrollments  ->  http://host:4000/enrollments
http://host:4000/v1/  + enrollments  ->  http://host:4000/v1/enrollments
```

Every request missed the `/v1` scope, Phoenix had no route, and the app blamed the join code. The
study was open, the code was correct, and the server logs showed a 404 on a path nobody had thought
about.

**The specific cause is fixed.** `StudyController` now normalises the base URI to end in a slash,
with tests. This task is about the reporting, which is still wrong for any *other* way a request can
miss its route — a reverse proxy stripping a prefix, a load balancer misrouting, a server deployed
under a path.

## What makes it fixable

The two cases are already distinguishable on the wire. A refusal from this server is
[RFC 9457](https://www.rfc-editor.org/rfc/rfc9457) problem details, which the ingest contract
specifies:

```
HTTP/1.1 404 Not Found
content-type: application/problem+json

{"type":"about:blank","title":"Not Found","status":404,
 "detail":"No open study matches that join code.","instance":"/v1/enrollments"}
```

A framework 404 for an unrouted path is not that: different content type, no `title` we chose, no
`instance` naming a path we serve.

So the discriminator is **`content-type: application/problem+json`**, not the status code. If it is
absent, the server did not refuse the request — it never saw it.

## What needs doing

1. **A shared helper** that classifies a response into "the server refused this" versus "this did not
   reach the server as intended", by content type and by whether the body parses as problem details.

2. **A distinct failure** — `EnrollmentFailure.unreachableEndpoint` or similar — with participant
   text that points at the right thing: *"Cannot reach the study server. Check the address the app
   was built with."* The current text should be reserved for a genuine refusal.

3. **Apply it to the other three call sites.** `tokens.dart`, `ingest_client.dart` and
   `state_channel.dart` all switch on bare status codes and have the same ambiguity. `StateChannel`
   has already noticed it once, in a comment:

   > A 404 after a document has been seen is far more likely to be a routing or deployment problem
   > than a real deletion, so the cache is kept.

   That reasoning is right and should be a shared rule rather than a local judgement call repeated
   four times with different conclusions.

4. **Consider surfacing the resolved URL** in the failure detail. "No route to
   `http://host:4000/enrollments`" would have made this self-diagnosing in seconds.

## The judgement worth making deliberately

How much should the client trust a content type? A misconfigured proxy could return
`application/problem+json` for something the server never saw, and a future server version could
refuse without it.

The safe reading is that problem details are *evidence of a refusal*, and their absence is *evidence
of not arriving* — neither being proof. Both messages should therefore be phrased as the more likely
explanation rather than a verdict, which is also what keeps them honest when the guess is wrong.

## How it would be verified

- A stubbed 404 with `application/problem+json` maps to the existing "no open study" failure.
- A stubbed 404 *without* it maps to the new unreachable-endpoint failure.
- The same pair for token refresh, ingest and the state channel.
- An end-to-end check against a real server on a wrong base path, asserting the participant-facing
  message names the address rather than the join code.

Seeded defects worth confirming are caught: classifying purely on status again; treating any 404 as
unreachable, which would hide a genuine unknown code.
