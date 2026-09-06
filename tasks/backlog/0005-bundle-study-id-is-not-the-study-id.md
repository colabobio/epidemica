# 0005 — The study id in the bundle is not the study id

**Status:** backlog
**Filed:** 2026-09-03
**Touches:** `contracts/bundle/1.0.0.json`, `server/lib/epidemica_server/studies.ex`,
`server/lib/mix/tasks/epidemica.seed_study.ex`, `studies/*/bundle.json`,
`docs/concepts/building-a-study.md`

## The problem

A bundle declares a `study_id`. The server never reads it. `create_study_from_bundle/2` stores the
bundle's bytes, its decoded form and its hash, and lets Postgres generate `studies.id`:

```elixir
create_study(%{
  name: name,
  protocol_source: source,
  protocol: decoded,
  protocol_hash: Study.hash_of(source)
})
```

So every study has two identities. The one an author wrote and can see in the file they are editing,
and the one the system actually uses — generated at seed time, different on every machine and after
every `ecto.reset`.

Worse, the contract's description of the field claims two things, both false:

> "The study these observations belong to. Also the seed for the proximity service UUID, so devices
> in different studies never discover one another."

Observations carry the *server's* id: the app stores `body['study_id']` from the enrollment response
into `Enrollment.studyId`, and that is what is stamped on every envelope. The service UUID is
derived from the same value — `studyServiceUuid(context.studyId)` in `proximity_module.dart`, where
`context.studyId` is the enrollment's, not the bundle's. Nothing reads the authored field at all.

## How it showed up

During the first epigames field test. The bundle said `e9160a7e-0007-4a11-8b22-c3d4e5f60007`, so
that is the id used to advance the simulation:

```
mix epidemica.tick --study e9160a7e-0007-4a11-8b22-c3d4e5f60007 --day 2
** (Mix) no study e9160a7e-0007-4a11-8b22-c3d4e5f60007
```

The real id was `b82884b8-0513-4e4b-87cb-3e408321bd4b`, printed by `epidemica.seed_study` at seed
time and otherwise only findable in the database. The failure is loud here, which is the good case.
The bad case is a bundle id that *does* match something — after a reset, or on a second machine —
and operates silently on the wrong study.

## What has to be decided

This is a design question, not a repair, which is why it is filed rather than fixed.

**Either the bundle's id is authoritative** — the server inserts `studies.id` from the bundle, and a
study has one identity everywhere: in the file, in the database, in the tick command, on every
envelope. Authors can then write scripts and documentation against an id they control, and a study
seeded on two servers is the same study. The cost is that a copied-and-edited bundle silently
collides with its original unless seeding checks for it, and the id becomes part of the hashed
protocol, so it cannot be corrected without a new protocol version.

**Or the field is removed** — the server's id is the only one, `epidemica.seed_study` already prints
it, and the contract stops describing something it does not do. Cheaper, and honest, but it leaves
authors with no stable handle on a study across environments.

The first is the better answer if studies are ever seeded on more than one server, which they will
be as soon as a study runs anywhere other than a laptop.

## What is already in place

- `epidemica.seed_study` is idempotent on `protocol_hash`, so re-seeding the same bytes already
  finds the existing study rather than making a second one. An authored id would fit that shape.
- The bundle is stored verbatim, so the authored id is already in the database, just unused.
- Both bundles in `studies/` carry a plausible id (`c0badf00-…`, `e9160a7e-…`), as does the example
  in `docs/concepts/building-a-study.md`. Adopting them changes no authored file.

## What blocks it

Nothing technical. It needs the decision above, and if the bundle's id wins:

- a uniqueness failure at seed time must be a clear message about a duplicated bundle, not an Ecto
  constraint error;
- the contract description must be rewritten either way, because it is currently wrong about both
  observations and the service UUID regardless of which option is chosen;
- `docs/concepts/building-a-study.md` should say what the field is for, which it does not today.

## How it would be verified

- Seeding a bundle produces a study whose `id` is the bundle's `study_id`.
- Enrolling against it returns that same id, and an envelope submitted by the app carries it.
- `mix epidemica.tick --study <the id in the bundle>` works, which is the thing that failed.
- Seeding two different bundles that share a `study_id` fails with a message naming the collision.
- A teeth check: make the server generate its own id again and confirm the first test fails.
