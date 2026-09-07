# 0006 — Nothing uploads unless a participant is looking at the screen

**Status:** partly done — the trigger mechanism landed 2026-09-06; **stays in backlog** because
neither the Android case that matters nor any device verification is done.
**Filed:** 2026-09-03
**Touches:** `packages/epidemica_core/lib/src/sync/`, `packages/epidemica_core/lib/src/study_controller.dart`,
`packages/epidemica_proximity_android/android/src/main/kotlin/.../ProximityService.kt`,
`packages/epidemica_proximity_ios/ios/.../ProximitySensor.swift`, `apps/epigames`, `apps/template`

## What landed, 2026-09-06

A trigger path from the platform to the outbox, described in
[`docs/concepts/background-sync.md`](../../docs/concepts/background-sync.md).

- Native emits a `ProximityWake` when the OS gives the process execution time: Android's foreground
  service every five minutes, iOS on a BLE detection throttled to once a minute.
- `ProximityModule` turns it into `ModuleContext.requestSync()` and applies no policy of its own.
- `StudyController.syncThrottled()` decides whether to act, through `SyncThrottle`: a five-minute
  platform floor a study cannot shorten, extended by `sync.min_interval_seconds` when the bundle
  declares a longer one. **That field had never been read by anything until now.**
- A wake goes through `ProximityEvents.offer`, not `emit`, so it is dropped rather than buffered
  when nothing is listening. Buffering it would have cost a detection its place in a
  fixed-capacity buffer whose overflow is reported as lost observation.

## Why this is not done

**1. The Android case that matters is not fixed.** `stopWithTask="false"` keeps the *service* alive
when the app is swiped from recents, but `onDetachedFromEngine` detaches the event sink and the
Flutter engine is gone. Sensing continues, the outbox fills, and nothing drains it because there is
no Dart isolate to drain it — the wake is offered to nobody. What landed helps only while the engine
is attached, which on Android largely overlaps with what the existing foreground timer already did.

Closing this needs a Dart entrypoint the service can host: a background isolate via
`DartExecutor` and a callback handle, or `WorkManager` with one. That is the remaining work, and it
is most of the original problem.

**2. iOS works, but only as often as there are people around.** The wake arrives on a BLE detection,
so a participant who spends a day alone uploads nothing until they open the app. Acceptable — the
signal of interest is contact, and contact is what wakes the device — but it is a property of the
design rather than an implementation detail, and it should be stated in any methods section.

**3. Nothing has been verified on hardware.** The acceptance criteria below are device tests. None
has been run. Whether iOS delivers enough wakes to matter in practice is empirical and this code
does not answer it.

## Decided

**Should a participant be told their dataset depends on not force-quitting the app?** Yes. A
paragraph has been added to the Epigames info screen. Its wording, and whether it belongs in consent
rather than in an info screen, is a review question for the PI.

---

## The problem

Every sync in the platform is driven by a Dart `Timer` owned by a widget:

```dart
// apps/epigames/lib/src/app.dart:51
_poll = Timer.periodic(const Duration(minutes: 1), (_) => _refresh());

// apps/template/lib/src/app.dart:38
_sync = Timer.periodic(const Duration(minutes: 5), (_) => widget.controller.sync());
```

Plus pull-to-refresh. That is the complete list of triggers — there is no `WorkManager`, no
`BGTaskScheduler`, no background isolate, and no platform-side upload anywhere in the repository.

Sensing does not stop when the app goes away; **uploading does.** So a participant who pockets
their phone at 18:00 and next opens the app at 09:00 has fifteen hours of correctly recorded
observations sitting on the device.

## Why it matters more than it looks

The existing comment in the template says this is "about promptness, not safety":

```dart
// Foreground sync only. Background scheduling is deliberately not wired yet: the outbox
// already guarantees nothing is lost while offline, so this is about promptness, not safety.
```

**That was true for a collection-only study and is false for one with a twin.** A tick freezes the
record at `received_before` and is immutable. Promptness *is* correctness once a deadline exists.

Trace what happens to a participant who sleeps with the app closed:

1. `module_status` observations stop being uploaded, so the server has no coverage assertion for
   the night.
2. The nightly tick runs. `Health.insufficiently_observed` finds coverage below `0.5` and returns
   the participant.
3. `Twin.protected_subjects` unions them into the protected set: **they cannot catch or transmit
   anything that day**, so the simulated epidemic routes around them.
4. `Epigame.settle_day` scores the day `not_sensing`: **zero points, no contacts, no protection
   they chose.**
5. The tick is immutable. When the app finally syncs, the observations arrive, land in
   `observations`, project into `contacts` — and change nothing. Contacts may be recovered by
   `award_carry_over`; **transmission never is.**

So the participant who behaves most normally — phone in pocket, app closed — is the one the study
silently drops. For Epigames that is a broken game. For a real transmission study it is a
systematic bias against exactly the unattended overnight contact the study exists to measure.

## What is already in place

More than you would expect. This is a scheduling gap, not an architecture gap.

- **`SyncService.syncOnce` was built for this.** It takes no timers and holds no schedule:
  *"One pass, no timers: when to call this is a policy decision that belongs to whatever is
  managing the background service, not here."*
- **The outbox is safe to drain from another isolate.** SQLite runs in WAL with
  `busy_timeout` and `synchronous = FULL`, and `database.dart` states this is *"a multi-isolate
  strategy"*. `seq` is allocated by the same `INSERT` that writes the row, claims are token-scoped,
  and `reclaimStale/1` recovers a claim whose owner died mid-flight.
- **Android already runs a foreground service.** `ProximityService` is
  `foregroundServiceType="connectedDevice"`, `stopWithTask="false"`, returning `START_STICKY`, with
  a persistent notification. A process that is already alive and already user-visible is the
  cheapest possible place to put a periodic upload.
- **iOS already declares `bluetooth-central` and `bluetooth-peripheral`**, and
  `ProximitySensor.swift` already handles being relaunched for BLE state restoration. iOS wakes the
  app for detections; that wake is a natural upload opportunity requiring no new background mode.
- **Tokens survive long gaps.** Access tokens last 30 days and refresh 365, and `TokenStore`
  refreshes with a two-minute margin. A night, or a month, is not a problem.
- **`sync.min_interval_seconds` is already in the bundle contract** and already parsed by
  `ProtocolBundle.minSyncInterval` — and currently read by nothing. This is the task that would
  finally honour it.

## What actually blocks it

1. **Deciding the mechanism per platform, because they are not symmetrical.**

   *Android* is nearly free: the foreground service exists and is already alive. Either post
   periodic work to it, or use `WorkManager` (15-minute minimum period, survives reboot). The
   trade-off is that `WorkManager` gets a fresh Dart isolate and must open its own database
   handle; the service could instead signal the existing isolate.

   *iOS* has no equivalent guarantee. `BGAppRefreshTask` is opportunistic and the system may
   simply not run it. The more reliable hook is the BLE background wake the app already receives:
   when Herald reports a detection in the background, drain the outbox then. It needs no new
   entitlement, but it means upload frequency is a function of how many people are nearby — which
   is acceptable, and should be stated rather than hidden.

2. **Where it lives.** It belongs in `epidemica_core`, not in `apps/epigames`. Every study needs
   it, and a policy each app re-implements will diverge.

3. **A floor, and a cellular budget.** `min_interval_seconds` becomes the lower bound. Uploading
   every BLE wake on a crowded train would be pathological, so the scheduler needs its own rate
   limit independent of the study's.

4. **Coverage reporting has the same problem and a different fix.** `ModuleHealthReporter` is also
   a Dart `Timer`, so a suspended isolate stops asserting coverage — and worse, over-claims it on
   resume. See [`0007`](0007-coverage-over-claims-after-a-suspension.md). Fixing sync alone would
   deliver a night of health observations that are themselves wrong.

## How it would be verified

Unit-testable:

- The scheduler honours `min_interval_seconds` and its own floor, whichever is longer.
- Two concurrent drains (foreground timer and background trigger) do not double-deliver: one
  claims, the other finds nothing, and `reclaimStale` returns an abandoned claim.
- A background drain uses its own database handle and does not corrupt the foreground's.

Device tests, which are the ones that actually decide it:

- Android: background the app for four hours with the screen off and Doze active; observations must
  arrive without the app being opened. Repeat with the app swiped from recents — `START_STICKY`
  and `stopWithTask="false"` should keep it running.
- iOS: same, and separately after a force-quit, which should **not** resume. Whether iOS delivers
  enough wakes to be useful is the open empirical question, and the answer belongs in an ADR.
- Both: airplane mode for an hour, then reconnect — the backlog drains without duplicates.
- End to end: leave two phones together overnight with the apps closed, tick the next morning, and
  confirm the participants are **not** scored `not_sensing`. That is the failure this task exists
  to remove, and it is the only test that demonstrates it.

## Worth deciding at the same time

Whether a participant should be *told*. A study that depends on background upload has an interest
in the phone not being force-quit, and saying so once at enrolment is more honest than silently
producing a worse dataset for the participants who tidy their app switcher.
