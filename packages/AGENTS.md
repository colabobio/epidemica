# packages/AGENTS.md

Dart client packages, resolved as one pub workspace from the root `pubspec.yaml`. A new package must
be listed there or it will not resolve.

```sh
flutter analyze apps packages          # must report zero issues
cd packages/<name> && flutter test
dart format --line-length 100 lib test # only the files you changed
```

## The boundary that matters

`epidemica_core` must not depend on any module. Core defines `EmbeddedModule`, the outbox, sync and
the state channel; modules implement against them. A module gets a `ModuleContext` and nothing more
— its own config block, the study id, the subject, a recorder, a store, and the two instants it may
need to time things against. Deliberately narrow: a module that can read the whole bundle grows
opinions about other modules' configuration, and the coupling stays invisible until two studies
disagree.

## Never synthesise what the server computes

An invented "you are healthy" is indistinguishable on screen from a measured one, and a participant
would act on it. `StateChannel` returns null rather than a default, and the app renders nothing
rather than a guess.

The converse is also true and was a real bug: **present-tense facts must not be read from a settled
document.** Whether the radio is on now is a question only the device can answer; whether the
participant's own protection is running now comes from `protected_until`, not from
`protection_source`, which records why a *settled* day was protected.

## Observations are durable, uploads are not guaranteed

The outbox is SQLite in WAL mode and survives termination. `SyncService.syncOnce` is one pass with
no timers — when to call it is a policy decision that belongs to whatever manages the background
service, not to core. There is currently no background sync
([`tasks/backlog/0006`](../tasks/backlog/0006-no-background-sync.md)).

A client removes an observation from the outbox on **absence** from the server's exception list, not
on acknowledgement. Removing only what the server listed would delete the failures, keep every
success, and resend them for ever.

## Coverage is asserted positively

A period with no `module_status` report is *uncovered*, not quiet. A killed app cannot report
anything, so absence of evidence must never read as evidence of absence. Note the known inversion
across a suspension in [`tasks/backlog/0007`](../tasks/backlog/0007-coverage-over-claims-after-a-suspension.md).

## Mirrored logic is held by shared vectors

`apps/epigames/lib/src/rules.dart` mirrors the server's scoring so a participant sees a contact land
immediately. The two are held to `contracts/game/epigame_rules/1.0.0.vectors.json`, the same file
the Elixir tests run. Change one side and you must change the vectors, or they have drifted and the
number on screen has stopped meaning the number in the ledger.
