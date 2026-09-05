# Background sync

How observations get off the device when nobody is looking at the screen, why the implementation
differs by platform, and what it does not prove.

For why this exists, start with [task 0006](../../tasks/done/0006-no-background-sync.md), which is the
investigation this design was built against — a participant who behaves most normally (phone in
pocket, app closed) was previously the one the study silently dropped.

## The constraint that shapes everything

A platform observation is only useful once it has reached the server, and a device that has stopped
being foregrounded cannot run a Dart timer to get it there. Sensing continues in the background —
Bluetooth keeps working, detections keep arriving, the outbox keeps filling — but nothing before this
existed to drain it. The gap was invisible in testing because every test so far had someone
foregrounding the app often enough to notice nothing was wrong.

`SyncService.syncOnce()` was already built for this deliberately: it takes no timer and holds no
schedule, because when to call it is a policy decision that belongs to whoever owns the background
service, not to the upload code itself. This document is about where those triggers come from.

## Why the platform owns the "when"

The central design choice is that Dart does not decide when a background sync is appropriate. A Dart
`Timer` dies with the process; a background wake is a platform resource Dart can only receive, not
initiate. So the native side says *this is a moment when a sync is appropriate*, and Dart decides
*whether to act on it*. Neither side duplicates the other's job, and neither has to know how the
other makes its decision.

The signal travels through the same event channel detections already use: a `sync_due` event emitted
by native code, delivered through `ProximityEvents` (which buffers until Dart attaches, so it cannot
be dropped in transit), decoded in the platform interface, and surfaced in Dart as a `SyncDue` event
on the module's stream. A module that receives it does not itself know what an upload is — it is
given a callback by whoever owns it, and that callback is `StudyController.syncThrottled()`.

## Android: the foreground service already exists

On Android this is close to free, because the resource needed is already running.

`ProximityService` is a foreground service with `foregroundServiceType="connectedDevice"` and
`stopWithTask="false"` — which is what it takes to keep Bluetooth scanning alive after the screen
locks at all. A process that is already alive and already holds a persistent notification is the
cheapest possible place to put a periodic trigger: no new process to start, no new permission to
request, no `WorkManager` dependency for a 15-minute minimum period that a foreground service can
simply own.

The service posts itself a delayed `Runnable` every five minutes on the main looper and emits
`sync_due`. Five minutes is a lower bound, not a guarantee — the Dart side applies its own floor on
top (see below), and neither number is under the study's control to shorten.

`START_STICKY` is already there for sensing, and it applies to this too: a service restarted after
the system killed it for memory gets a null intent, which the existing code already handles by
stopping rather than guessing, so the sync offers stop with it rather than firing meaninglessly.

## iOS: there is no timer to own, so the wake is the trigger

iOS has no equivalent guarantee. `BGAppRefreshTask` exists but is opportunistic in a way the
documentation is unusually honest about: the system decides when, and may simply decide never. A
study whose data collection depends on an event the OS may not deliver is not a study.

What iOS *does* deliver reliably is a wake on a BLE detection, because the app declares
`bluetooth-central` and `bluetooth-peripheral` background modes and Herald already handles state
restoration. So rather than ask for an additional background mode with no stronger guarantee, the
detection itself is also treated as the sync opportunity: `ProximitySensor`'s existing
`sensor(_:didMeasure:fromTarget:withPayload:)` callback emits `sync_due` immediately after the
detection event it was already emitting.

The consequence is worth stating plainly: upload frequency on iOS is a function of how many other
participants are nearby, not a schedule. That is an acceptable trade-off — the signal of interest is
contact with other participants, and the wake that enables upload is caused by exactly that contact —
but it is a trade-off, and it is stated here rather than hidden in an assumption about scheduling
that iOS does not make.

## The floor, and why it lives in core

A signal that fires as often as the platform offers would be pathological: on a crowded commute, a
BLE detection is not a rare event. The floor lives in `epidemica_core` as `SyncThrottle`, not in
either app, because a rate limit re-implemented per app is a rate limit that diverges.

`StudyController.syncThrottled()` is the only caller that should act on a `sync_due` event, and it
enforces two floors simultaneously:

1. **A platform floor** — `StudyController.syncFloor`, currently five minutes — that no study can
   shorten. This exists because the platform is the only thing that knows what a pathological
   trigger frequency looks like.
2. **The study's own declared floor**, from `sync.min_interval_seconds` in the bundle — parsed since
   before this existed, read by nothing until now. A study that needs slower uploads declares it here;
   a study that says nothing gets the platform floor alone.

Both apply: the effective interval is whichever is longer. This finally honours a field the bundle
contract has carried since before the mechanism to read it existed.

## What this does not prove

The plumbing is in place and unit-tested. What it has not done is run on a physical device long
enough to know whether it works — and the task file is explicit that this is the real acceptance
criterion, not a nicety:

- Android: four hours with the screen off and Doze active, observations must arrive without the app
  being opened. Repeated with the app swiped from recents.
- iOS: the same, and separately after a force-quit, which should **not** resume.
- Both: airplane mode for an hour, then reconnect — the backlog must drain without duplicates.
- End to end: two phones together overnight with the apps closed, ticked the next morning, and
  confirmed not scored `not_sensing`. That last test is the one this feature exists to pass, and it
  is also the one that cannot be checked by `flutter test`.

Whether iOS delivers enough background wakes to be useful in practice is an empirical question this
code deliberately does not claim to answer. The task file's own "Worth deciding at the same time" —
whether a participant should be told that force-quitting the app degrades their dataset — is answered
yes: a sentence has been added to the enrolment info screen saying so, and its exact wording is a
review question for the PI rather than a settled claim.

## Where things live

| Piece | File |
|---|---|
| The platform floor and the decision to act | `packages/epidemica_core/lib/src/study_controller.dart` (`syncThrottled`, `syncFloor`) |
| The rate limiter itself | `packages/epidemica_core/lib/src/sync/sync_throttle.dart` |
| The event type | `packages/epidemica_proximity_platform_interface/lib/src/proximity_event.dart` (`SyncDue`) |
| Wire decoding | `packages/epidemica_proximity_platform_interface/lib/src/method_channel_proximity.dart` |
| Android trigger | `packages/epidemica_proximity_android/android/src/main/kotlin/info/epidemica/proximity/ProximityService.kt` |
| iOS trigger | `packages/epidemica_proximity_ios/ios/epidemica_proximity_ios/Sources/epidemica_proximity_ios/ProximitySensor.swift` |
| The app's callback wiring | `apps/epigames/lib/main.dart`, `apps/template/lib/main.dart` |
| The investigation this implements | [`tasks/done/0006`](../../tasks/done/0006-no-background-sync.md) |
