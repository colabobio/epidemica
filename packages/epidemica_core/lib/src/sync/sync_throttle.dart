import 'dart:async';

/// Rate-limits something that can fire whenever the platform feels like it.
///
/// A background wake is an offer, not a schedule: on iOS it arrives on a BLE detection, so in a
/// crowded room it arrives constantly, and acting on every one would drain a participant's battery
/// to upload nothing. The floor is what turns an irregular offer into a bounded rate.
///
/// Holds only its own last-run instant. Deliberately not a `Timer`: the process this runs in is
/// suspended and resumed by the operating system, and a timer does not survive that.
class SyncThrottle {
  SyncThrottle({required this.floor, DateTime Function()? now}) : _now = now ?? DateTime.now;

  /// The shortest interval this will ever allow, whatever a study asks for.
  ///
  /// A study can ask for less frequent uploads and get them; it cannot ask for more frequent ones.
  /// What counts as a pathological trigger rate is a property of the platform and the battery, not
  /// of the research question.
  final Duration floor;

  final DateTime Function() _now;
  DateTime? _lastRunAt;

  DateTime? get lastRunAt => _lastRunAt;

  /// [floor] and a study's own declared floor, whichever is longer.
  Duration effectiveFloor([Duration? studyFloor]) =>
      studyFloor != null && studyFloor > floor ? studyFloor : floor;

  /// Runs [action] at most once per [effectiveFloor], and reports whether it ran.
  ///
  /// A skipped run is the normal case rather than a failure, which is why it is a return value and
  /// not an exception. The attempt is recorded before [action] is awaited, so a failing upload is
  /// retried at the floor rather than as fast as the platform offers: a device with no connectivity
  /// would otherwise spend the battery discovering that repeatedly.
  Future<bool> run(FutureOr<void> Function() action, [Duration? studyFloor]) async {
    final now = _now();
    final last = _lastRunAt;

    if (last != null && now.difference(last) < effectiveFloor(studyFloor)) {
      return false;
    }

    _lastRunAt = now;
    await action();
    return true;
  }
}
