import 'dart:async';

/// Rate-limits a call so something that can fire opportunistically — a background trigger, a
/// foreground timer, a manual retry — cannot fire more often than it should.
///
/// The specific case this exists for: a background sync driven by a device's BLE wake could fire
/// as often as the device sees another device, which on a crowded commute would be pathological
/// without a floor, and the study's own declared floor (`sync.min_interval_seconds`) is only a
/// lower bound this must honour, not a substitute for one.
///
/// Stateless apart from its own last-run timestamp, and deliberately so: a trigger that can fire
/// from two isolates cannot safely share a `Timer`, and neither can an app that backgrounded
/// between runs.
class SyncThrottle {
  SyncThrottle({required this.floor, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// The minimum time between runs this object will ever allow.
  final Duration floor;

  final DateTime Function() _now;
  DateTime? _lastRunAt;

  /// The [floor] merged with an optional study floor, whichever is longer.
  Duration effectiveFloor([Duration? studyFloor]) =>
      studyFloor != null && studyFloor > floor ? studyFloor : floor;

  /// Runs [action] at most once per [effectiveFloor].
  ///
  /// Returns `true` if the action ran, `false` if it was skipped for rate limiting. Callers that
  /// need to know *why* nothing happened check the return rather than relying on a side effect,
  /// because a skipped run is not an error here — it is the point.
  Future<bool> run(FutureOr<void> Function() action, [Duration? studyFloor]) async {
    final now = _now();
    final wait = _lastRunAt == null ? null : effectiveFloor(studyFloor) - now.difference(_lastRunAt!);
    if (wait != null && wait > Duration.zero) {
      return false;
    }
    _lastRunAt = now;
    await action();
    return true;
  }
}
