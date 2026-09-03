# 0007 — Coverage is over-claimed after a suspension

**Status:** backlog
**Filed:** 2026-09-03
**Touches:** `packages/epidemica_core/lib/src/modules/module_health.dart`,
`packages/epidemica_core/test/module_health_test.dart`

## The problem

`ModuleHealthReporter` documents a guarantee it does not always keep:

```dart
/// **A period with no report is uncovered.** That is the whole design: a killed app cannot report
/// anything, so absence of evidence must not read as evidence of absence. Consecutive windows abut,
/// so any gap between them is a real gap.
```

The abutting is the problem. `_coveredTo` is in-memory instance state, and every report runs from
it to *now*:

```dart
Future<void> report() async {
  final until = _now().toUtc();
  for (final module in modules) {
    final since = _coveredTo[module.id];
    if (since == null || !until.isAfter(since)) continue;
    final ModuleStatus status;
    try { status = await module.status(); } on Object catch (e) { ... }
    _emit(module.id, status, since, until);   // one window, however long
    _coveredTo[module.id] = until;
  }
}
```

There are two ways the timer can stop, and they behave oppositely:

| | `_coveredTo` | Result |
|---|---|---|
| **Process killed**, app relaunched | Lost; `start()` re-seeds it to now | Gap is real. Correct. |
| **Isolate suspended**, then resumed | Survives | The next report emits **one window covering the entire gap**, stamped with whatever the module's status is *at that moment* |

In the second case the reporter asserts `state: sensing` for a period it observed nothing about.
`Health.coverage/4` unions the window and the participant is credited with full coverage of a night
the app spent suspended.

**Absence of evidence is being converted into evidence of presence** — the exact inversion the
module says it exists to prevent.

## Why it matters

Coverage is not diagnostics. It decides whether a participant is treated as observed, and therefore
whether the twin lets them catch anything and whether their day is scored. Both failure directions
are harmful and they are harmful in different ways:

- **Under-claiming** (task [`0006`](0006-no-background-sync.md)) marks a real participant
  `not_sensing`, drops them from transmission, and scores them zero.
- **Over-claiming** — this task — is worse for the science. It tells the model a participant was
  observed all night and met nobody. That is not a missing datum the analysis can exclude; it is a
  **false zero**, indistinguishable from a genuine night alone, and it biases any contact-rate
  estimate downward without leaving a trace.

The exposure is worst exactly where sensing is least reliable. On iOS the Flutter isolate is
routinely suspended and resumed while the process survives, which is the over-claiming case; on
Android the foreground service tends to keep the isolate alive, so reports keep flowing honestly.

## How it was found

Reading the code while writing [`docs/concepts/epigame.md`](../../docs/concepts/epigame.md). It has
not been observed in the field, and confirming it needs a device — see verification below.

## What is already in place

- The termination case is correct and **already tested**:
  `module_health_test.dart:87` — *"a period the app was not running for is simply never covered"* —
  constructs a fresh reporter and asserts the six-hour gap is absent from the record.
- `start({DateTime? from})` already takes the window origin, and uses `putIfAbsent`, so it is
  ready to be told "resume from now" rather than inferring it.
- `flush()` already exists to close a window deliberately on shutdown.
- The server tolerates whatever it is told: `Health.covered_microseconds` unions overlapping
  windows, so emitting more, shorter windows costs nothing but observations.

## What actually blocks it

Deciding what a resumed reporter should claim, which is a real question rather than a typo:

1. **Cap the window at one interval.** If more than `interval` has elapsed since `_coveredTo`,
   report only the most recent `interval` and leave the remainder uncovered. Simple, honest, and
   loses genuine coverage on Android where the isolate really did stay alive.

2. **Observe the app lifecycle.** Add a `WidgetsBindingObserver` — there is currently **none
   anywhere in the repo** — and on `paused`, `flush()` to close the window honestly; on `resumed`,
   re-seed `_coveredTo` to now so the suspended period is never claimed. Most accurate, and makes
   the reporter depend on Flutter bindings, which `epidemica_core` has so far avoided in this
   module.

3. **Have the platform assert its own coverage.** Android's foreground service genuinely knows
   whether it was scanning; so does Herald on iOS. Coverage claimed by the component that did the
   sensing is the only version that cannot be wrong. Much the largest change, and the right answer
   eventually.

(2) is probably right now, with (3) as the destination. (1) is a stopgap that trades a real bias
for a smaller one.

There is also a **contract question**: `module_status` has no field distinguishing "I watched this
window" from "I am reporting on a window I cannot vouch for". Adding one would let analysis filter
rather than trust, and would make the fix verifiable in stored data rather than only in tests.

## How it would be verified

- A test for the missing case: one reporter object, a simulated eight-hour gap between `report()`
  calls, asserting the emitted windows do **not** span the gap. Today that test fails.
- A teeth check: restore the abutting behaviour and confirm the new test fails.
- The existing termination test must keep passing — the fix must not turn a real gap into two.
- Lifecycle test, if (2): `paused` emits a closing window; `resumed` starts a fresh one; nothing
  covers the interval between.
- On a device: background an iOS app for two hours, return, sync, and inspect `module_status` in
  the database. Windows should show a two-hour hole, not a two-hour claim. **This is also the test
  that establishes whether the bug reproduces at all**, since it depends on the isolate being
  suspended rather than killed.
