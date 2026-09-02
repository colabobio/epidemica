import 'dart:async';

import 'embedded_module.dart';

/// Records, periodically, whether each module was actually collecting.
///
/// The point is not diagnostics. A study whose model infers exposure from an absence of contacts
/// cannot tell "this participant met nobody" from "we were not listening", and the difference
/// decides whether someone is treated as exposed. Coverage has to be stated positively.
///
/// **A period with no report is uncovered.** That is the whole design: a killed app cannot report
/// anything, so absence of evidence must not read as evidence of absence. Consecutive windows abut,
/// so any gap between them is a real gap.
class ModuleHealthReporter {
  ModuleHealthReporter({
    required this.modules,
    required this.recorderFor,
    this.interval = const Duration(hours: 1),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static const String schemaUri =
      'https://schemas.epidemica.info/observations/health/module_status/1.0.0.json';

  final List<EmbeddedModule> modules;

  /// Supplies a recorder for one module, so each status is attributed to the module it describes
  /// rather than to a synthetic "health" module.
  final ObservationRecorder Function(String moduleId) recorderFor;

  final Duration interval;
  final DateTime Function() _now;

  final Map<String, DateTime> _coveredTo = {};
  Timer? _timer;

  /// Begin reporting. [from] is where the first window starts — usually when collection began.
  void start({DateTime? from}) {
    final at = (from ?? _now()).toUtc();
    for (final module in modules) {
      _coveredTo.putIfAbsent(module.id, () => at);
    }
    _timer ??= Timer.periodic(interval, (_) => report());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Emit one status per module, covering the period since that module was last reported on.
  Future<void> report() async {
    final until = _now().toUtc();

    for (final module in modules) {
      final since = _coveredTo[module.id];
      // A module that was never started is not silently reported as covered.
      if (since == null || !until.isAfter(since)) continue;

      final ModuleStatus status;
      try {
        status = await module.status();
      } on Object catch (e) {
        // A module that cannot answer is not sensing. Reporting nothing would leave the window
        // uncovered, which is also correct but tells analysis less.
        _emit(module.id, ModuleStatus(ModuleState.stopped, detail: '$e'), since, until);
        _coveredTo[module.id] = until;
        continue;
      }

      _emit(module.id, status, since, until);
      _coveredTo[module.id] = until;
    }
  }

  /// Close the current window before shutting down, so the last period is not left uncovered
  /// merely because collection ended tidily.
  Future<void> flush() => report();

  void _emit(String moduleId, ModuleStatus status, DateTime since, DateTime until) {
    recorderFor(moduleId)(
      schemaUri: schemaUri,
      observedAt: until,
      payload: {
        'state': status.state.toJson(),
        'window_start': _iso(since),
        'window_end': _iso(until),
        if (status.detail != null) 'detail': status.detail,
      },
    );
  }

  static String _iso(DateTime dt) {
    final s = dt.toUtc().toIso8601String();
    return s.endsWith('.000Z') ? '${s.substring(0, s.length - 5)}Z' : s;
  }
}
