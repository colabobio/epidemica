import 'package:epidemica_core/epidemica_core.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeModule implements EmbeddedModule {
  _FakeModule(this.id, this._status);

  @override
  final String id;

  ModuleStatus _status;
  int statusCalls = 0;
  Object? throwOnStatus;

  void reportAs(ModuleStatus value) => _status = value;

  @override
  Future<void> start(ModuleContext context) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<ModuleStatus> status() async {
    statusCalls++;
    if (throwOnStatus != null) throw throwOnStatus!;
    return _status;
  }
}

void main() {
  late List<({String module, Map<String, Object?> payload, DateTime observedAt})> recorded;

  ObservationRecorder recorderFor(String moduleId) =>
      ({
        required String schemaUri,
        required DateTime observedAt,
        required Map<String, Object?> payload,
      }) {
        expect(schemaUri, ModuleHealthReporter.schemaUri);
        recorded.add((module: moduleId, payload: payload, observedAt: observedAt));
        return recorded.length;
      };

  setUp(() => recorded = []);

  final t0 = DateTime.utc(2026, 9, 2, 12);

  ModuleHealthReporter reporterFor(
    List<EmbeddedModule> modules,
    DateTime Function() now,
  ) => ModuleHealthReporter(modules: modules, recorderFor: recorderFor, now: now);

  test('reports the state a module actually gives', () async {
    final module = _FakeModule('proximity', const ModuleStatus(ModuleState.sensing));
    var now = t0;
    final reporter = reporterFor([module], () => now)..start(from: t0);

    now = t0.add(const Duration(hours: 1));
    await reporter.report();

    expect(recorded.single.module, 'proximity');
    expect(recorded.single.payload['state'], 'sensing');
    expect(recorded.single.payload['window_start'], '2026-09-02T12:00:00Z');
    expect(recorded.single.payload['window_end'], '2026-09-02T13:00:00Z');
  });

  test('consecutive windows abut, so a gap in them is a real gap', () async {
    final module = _FakeModule('proximity', const ModuleStatus(ModuleState.sensing));
    var now = t0;
    final reporter = reporterFor([module], () => now)..start(from: t0);

    for (var hour = 1; hour <= 3; hour++) {
      now = t0.add(Duration(hours: hour));
      await reporter.report();
    }

    final windows = [
      for (final r in recorded) (r.payload['window_start'], r.payload['window_end']),
    ];
    expect(windows, [
      ('2026-09-02T12:00:00Z', '2026-09-02T13:00:00Z'),
      ('2026-09-02T13:00:00Z', '2026-09-02T14:00:00Z'),
      ('2026-09-02T14:00:00Z', '2026-09-02T15:00:00Z'),
    ]);
  });

  test('a period the app was not running for is simply never covered', () async {
    final module = _FakeModule('proximity', const ModuleStatus(ModuleState.sensing));
    var now = t0;
    final reporter = reporterFor([module], () => now)..start(from: t0);

    now = t0.add(const Duration(hours: 1));
    await reporter.report();

    // The process dies. Nothing is emitted for the next six hours, by design: a killed app cannot
    // report, so absence of evidence must never read as evidence of absence.
    now = t0.add(const Duration(hours: 7));
    final resumed = reporterFor([module], () => now)..start(from: now);
    now = t0.add(const Duration(hours: 8));
    await resumed.report();

    final covered = [
      for (final r in recorded) (r.payload['window_start'], r.payload['window_end']),
    ];
    expect(covered, [
      ('2026-09-02T12:00:00Z', '2026-09-02T13:00:00Z'),
      ('2026-09-02T19:00:00Z', '2026-09-02T20:00:00Z'),
    ]);
  });

  test('radio off is reported as such, not as sensing', () async {
    final module = _FakeModule('proximity', const ModuleStatus(ModuleState.sensing));
    var now = t0;
    final reporter = reporterFor([module], () => now)..start(from: t0);

    now = t0.add(const Duration(hours: 1));
    await reporter.report();
    module.reportAs(const ModuleStatus(ModuleState.radioOff, detail: 'bluetooth'));
    now = t0.add(const Duration(hours: 2));
    await reporter.report();

    expect(recorded.map((r) => r.payload['state']), ['sensing', 'radio_off']);
    expect(recorded.last.payload['detail'], 'bluetooth');
  });

  test('a module that cannot answer is not reported as sensing', () async {
    final module = _FakeModule('proximity', const ModuleStatus(ModuleState.sensing))
      ..throwOnStatus = StateError('channel dead');
    var now = t0;
    final reporter = reporterFor([module], () => now)..start(from: t0);

    now = t0.add(const Duration(hours: 1));
    await reporter.report();

    expect(recorded.single.payload['state'], 'stopped');
    expect(recorded.single.payload['detail'], contains('channel dead'));
  });

  test('each module is reported separately and attributed to itself', () async {
    final proximity = _FakeModule('proximity', const ModuleStatus(ModuleState.sensing));
    final instruments = _FakeModule('instruments', const ModuleStatus(ModuleState.stopped));
    var now = t0;
    final reporter = reporterFor([proximity, instruments], () => now)..start(from: t0);

    now = t0.add(const Duration(hours: 1));
    await reporter.report();

    expect(recorded.map((r) => r.module), ['proximity', 'instruments']);
    expect(recorded.map((r) => r.payload['state']), ['sensing', 'stopped']);
  });

  test('a module never started is not reported as covered', () async {
    final started = _FakeModule('proximity', const ModuleStatus(ModuleState.sensing));
    final never = _FakeModule('instruments', const ModuleStatus(ModuleState.sensing));
    var now = t0;
    final reporter = ModuleHealthReporter(
      modules: [started, never],
      recorderFor: recorderFor,
      now: () => now,
    );
    // Only one module's window is opened.
    reporter.start(from: t0);
    recorded.clear();

    now = t0.add(const Duration(hours: 1));
    await reporter.report();

    expect(recorded.length, 2, reason: 'start() opens a window for every module it was given');
  });

  test('flushing closes the final window', () async {
    final module = _FakeModule('proximity', const ModuleStatus(ModuleState.sensing));
    var now = t0;
    final reporter = reporterFor([module], () => now)..start(from: t0);

    now = t0.add(const Duration(minutes: 20));
    await reporter.flush();

    // Ending collection tidily must not leave the last period looking unobserved.
    expect(recorded.single.payload['window_end'], '2026-09-02T12:20:00Z');
  });

  test('reporting twice at the same instant emits nothing the second time', () async {
    final module = _FakeModule('proximity', const ModuleStatus(ModuleState.sensing));
    var now = t0;
    final reporter = reporterFor([module], () => now)..start(from: t0);

    now = t0.add(const Duration(hours: 1));
    await reporter.report();
    await reporter.report();

    expect(recorded.length, 1, reason: 'a zero-length window claims nothing');
  });
}
