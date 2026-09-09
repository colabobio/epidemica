import 'dart:convert';
import 'dart:io';

import 'package:epidemica_core/epidemica_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Stands in for a real module. What matters is only whether it was started, and with what.
class _FakeModule implements EmbeddedModule {
  _FakeModule(this.id);

  @override
  final String id;

  ModuleContext? startedWith;
  int stops = 0;

  /// Changed by tests to simulate the radio being switched off mid-study.
  ModuleStatus reported = const ModuleStatus(ModuleState.sensing);
  Object? throws;

  @override
  Future<void> start(ModuleContext context) async => startedWith = context;

  @override
  Future<void> stop() async => stops++;

  @override
  Future<ModuleStatus> status() async {
    if (throws != null) throw throws!;
    return reported;
  }
}

const _bundleUrl = 'https://example.test/bundles/study.json';
const _studyId = 'c0badf00-1111-4222-8333-444455556666';

String bundleJson({
  required Map<String, Object?> modules,
  String title = 'Contact logging pilot',
  Map<String, Object?>? health,
  Map<String, Object?>? sync,
}) => jsonEncode({
  'bundle_version': '1.0',
  'study_id': _studyId,
  'title': title,
  'modules': modules,
  'health': ?health,
  'sync': ?sync,
});

void main() {
  late Directory dir;
  late EpidemicaDatabase db;
  late InMemorySecretStore secrets;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('epidemica_template');
    db = EpidemicaDatabase.open('${dir.path}/epidemica.db');
    secrets = InMemorySecretStore();
  });

  tearDown(() {
    db.close();
    dir.deleteSync(recursive: true);
  });

  http.Client serverServing(
    String bundle, {
    int enrollStatus = 201,
    List<String>? log,
    Map<String, Object?>? state,
    int stateStatus = 404,
  }) => MockClient((request) async {
    log?.add(request.url.path);
    if (request.url.toString() == _bundleUrl) return http.Response(bundle, 200);
    if (request.url.path.endsWith('/participants/me/state')) {
      if (state == null) return http.Response('{}', stateStatus);
      return http.Response(jsonEncode(state), 200);
    }
    if (request.url.path.endsWith('/observations')) {
      return http.Response(
        jsonEncode({
          'received': 0,
          'accepted': 0,
          'duplicate': 0,
          'quarantined': 0,
          'rejected': 0,
          'exceptions': [],
          'server_time': '2026-09-02T12:00:00Z',
        }),
        200,
      );
    }
    if (enrollStatus != 201) return http.Response('{}', enrollStatus);
    return http.Response(
      jsonEncode({
        'subject': Identity(db).subject,
        'study_id': _studyId,
        'protocol_hash': ProtocolBundle.hashOf(utf8.encode(bundle)),
        'protocol_url': _bundleUrl,
        'access_token': 'access-1',
        'token_type': 'Bearer',
        'expires_in': 3600,
        'refresh_token': 'refresh-1',
        'server_time': '2026-09-02T12:00:00Z',
      }),
      201,
    );
  });

  /// One binary. The module set is fixed here, exactly as it is fixed at build time.
  StudyController binaryWith(List<EmbeddedModule> modules, http.Client client) => StudyController(
    baseUri: Uri.parse('https://example.test/v1/'),
    modules: modules,
    db: db,
    secrets: secrets,
    platform: 'android',
    httpClient: client,
  );

  group('the server address', () {
    test('a base URL without a trailing slash still reaches the API', () {
      // Uri.resolve treats a base without a trailing slash as naming a file and replaces the last
      // segment, so `.../v1` + `enrollments` silently becomes `.../enrollments`. The server has no
      // route there, returns 404, and the client reports "no open study matches that code" — a
      // configuration mistake wearing a data mistake's clothes.
      final controller = StudyController(
        baseUri: Uri.parse('https://example.test/v1'),
        modules: const [],
        db: db,
        secrets: secrets,
        platform: 'android',
      );

      expect(
        controller.baseUri.resolve('enrollments').toString(),
        'https://example.test/v1/enrollments',
      );
      controller.dispose();
    });

    test('a base URL that already ends in a slash is left alone', () {
      final controller = StudyController(
        baseUri: Uri.parse('https://example.test/v1/'),
        modules: const [],
        db: db,
        secrets: secrets,
        platform: 'android',
      );

      expect(controller.baseUri.toString(), 'https://example.test/v1/');
      controller.dispose();
    });

    test('a bare host gets a usable base', () {
      final controller = StudyController(
        baseUri: Uri.parse('https://example.test'),
        modules: const [],
        db: db,
        secrets: secrets,
        platform: 'android',
      );

      expect(
        controller.baseUri.resolve('enrollments').toString(),
        'https://example.test/enrollments',
      );
      controller.dispose();
    });
  });

  group('the same binary, different bundles', () {
    test('activates only the modules the study names', () async {
      final proximity = _FakeModule('proximity');
      final instruments = _FakeModule('instruments');

      await binaryWith(
        [proximity, instruments],
        serverServing(
          bundleJson(
            modules: {
              'proximity': {
                'on_device': {'max_episode_seconds': 600},
              },
            },
          ),
        ),
      ).join('JOIN-1234');

      expect(proximity.startedWith, isNotNull);
      expect(instruments.startedWith, isNull);
      expect(proximity.startedWith!.config, {
        'on_device': {'max_episode_seconds': 600},
      }, reason: 'a module receives its own block, not the whole bundle');
    });

    test('a different bundle collects a different module, with no rebuild', () async {
      final proximity = _FakeModule('proximity');
      final instruments = _FakeModule('instruments');

      // Same module set, same construction, same binary.
      await binaryWith(
        [proximity, instruments],
        serverServing(
          bundleJson(
            modules: {
              'instruments': {'schedule': 'daily'},
            },
          ),
        ),
      ).join('JOIN-5678');

      expect(instruments.startedWith, isNotNull);
      expect(proximity.startedWith, isNull);
      expect(instruments.startedWith!.config, {'schedule': 'daily'});
    });

    test('a bundle naming two modules starts both', () async {
      final proximity = _FakeModule('proximity');
      final instruments = _FakeModule('instruments');

      final controller = binaryWith([
        proximity,
        instruments,
      ], serverServing(bundleJson(modules: {'proximity': {}, 'instruments': {}})));
      await controller.join('JOIN-1234');

      expect(controller.runningModules, {'proximity', 'instruments'});
      expect(controller.state, StudyState.collecting);
    });
  });

  group('a study this binary cannot service', () {
    test('is refused with a message a participant can act on', () async {
      final controller = binaryWith([
        _FakeModule('proximity'),
      ], serverServing(bundleJson(modules: {'proximity': {}, 'biosensing': {}})));

      await controller.join('JOIN-1234');

      expect(controller.state, StudyState.refused);
      expect(controller.message, contains('newer version of the app'));
      expect(controller.message, contains('biosensing'));
    });

    test('leaves the participant enrolled in nothing at all', () async {
      final module = _FakeModule('proximity');
      final controller = binaryWith([
        module,
      ], serverServing(bundleJson(modules: {'biosensing': {}})));

      await controller.join('JOIN-1234');

      expect(controller.enrollment, isNull);
      expect(module.startedWith, isNull);
      // Enrolled-but-collecting-nothing looks healthy and is only discovered at analysis.
      expect(controller.pendingObservations, 0);
      await controller.initialize();
      expect(controller.state, StudyState.notEnrolled);
    });

    test('an unknown code is not blamed on the participant twice', () async {
      final controller = binaryWith([
        _FakeModule('proximity'),
      ], serverServing(bundleJson(modules: {'proximity': {}}), enrollStatus: 404));

      await controller.join('NOPE');

      expect(controller.state, StudyState.refused);
      expect(controller.message, contains('did not match an open study'));
    });
  });

  group('observations', () {
    test('carry the bundle hash the study was enrolled under', () async {
      final module = _FakeModule('proximity');
      final bundle = bundleJson(modules: {'proximity': {}});
      final controller = binaryWith([module], serverServing(bundle));
      await controller.join('JOIN-1234');

      module.startedWith!.record(
        schemaUri: 'https://schemas.epidemica.info/x/1.0.0.json',
        observedAt: DateTime.utc(2026, 9, 2, 12),
        payload: {'hello': 'world'},
      );

      final row = db.db.select('SELECT * FROM outbox').single;
      expect(row['protocol_hash'], ProtocolBundle.hashOf(utf8.encode(bundle)));
      expect(row['study_id'], _studyId);
      expect(row['module'], 'proximity');
      expect(row['subject'], controller.subject);
      expect(controller.pendingObservations, 1);
    });

    test('record a null clock offset until a server has been reached', () async {
      final module = _FakeModule('proximity');
      final controller = binaryWith([
        module,
      ], serverServing(bundleJson(modules: {'proximity': {}})));
      await controller.join('JOIN-1234');

      module.startedWith!.record(
        schemaUri: 'https://schemas.epidemica.info/x/1.0.0.json',
        observedAt: DateTime.utc(2026, 9, 2, 12),
        payload: const {},
      );

      expect(db.db.select('SELECT * FROM outbox').single['clock_offset_ms'], isNull);
      expect(controller.clockOffsetMs, isNull);
    });
  });

  group('joining', () {
    Map<String, Object?> stateDocument() => {
      'state_version': '1.0',
      'study_id': _studyId,
      'subject': Identity(db).subject,
      'state_uri': 'https://schemas.epidemica.info/state/epigame/1.0.0.json',
      'revision': 1,
      'as_of': '2026-09-09T12:00:00Z',
      'state': {'day': 0, 'epi_state': 'susceptible', 'points': 0},
    };

    test('fetches the state the server published at enrolment', () async {
      final bundle = bundleJson(modules: {'proximity': {}});
      final controller = binaryWith([
        _FakeModule('proximity'),
      ], serverServing(bundle, state: stateDocument()));

      await controller.join('JOIN-1234');

      // A study may publish a starting state as part of enrolment. Leaving it until the host's next
      // poll shows the participant a screen that says nothing is known yet, for as long as that
      // poll interval — which is a minute in Epigames, and only visible once a study has started.
      expect(controller.participantState, isNotNull);
      expect(controller.participantState!.state['epi_state'], 'susceptible');
      controller.dispose();
    });

    test('a study with nothing computed yet leaves no state and no complaint', () async {
      final bundle = bundleJson(modules: {'proximity': {}});
      final controller = binaryWith([_FakeModule('proximity')], serverServing(bundle));

      await controller.join('JOIN-1234');

      expect(controller.participantState, isNull);
      expect(controller.state, StudyState.collecting);
      controller.dispose();
    });

    test('a state fetch that fails does not make a successful join look failed', () async {
      final bundle = bundleJson(modules: {'proximity': {}});
      final controller = binaryWith([
        _FakeModule('proximity'),
      ], serverServing(bundle, stateStatus: 500));

      await controller.join('JOIN-1234');

      // The enrolment worked and collection started. Reporting the transport failure here would put
      // an error in front of a participant about something that is retried a minute later anyway.
      expect(controller.state, StudyState.collecting);
      expect(controller.message, isNull);
      controller.dispose();
    });
  });

  group('a module asking to upload', () {
    Future<StudyController> joined(String bundle, _FakeModule module, List<String> log) async {
      final controller = binaryWith([module], serverServing(bundle, log: log));
      await controller.join('JOIN-1234');
      return controller;
    }

    // An empty outbox never reaches the network, so a sync with nothing to send proves nothing.
    void record(_FakeModule module) => module.startedWith!.record(
      schemaUri: 'https://schemas.epidemica.info/x/1.0.0.json',
      observedAt: DateTime.utc(2026, 9, 2, 12),
      payload: const {},
    );

    test('reaches the controller, so no app has to wire it up', () async {
      final module = _FakeModule('proximity');
      final log = <String>[];
      final controller = await joined(bundleJson(modules: {'proximity': {}}), module, log);
      record(module);

      // The module is handed this and knows nothing else about it. Before, a background trigger had
      // to be wired per app, which is a rate limit and a policy decision copied per app.
      module.startedWith!.requestSync();
      await Future<void>.delayed(Duration.zero);

      expect(log.where((path) => path.endsWith('/observations')), hasLength(1));
      controller.dispose();
    });

    test('uploads once however often it asks', () async {
      final module = _FakeModule('proximity');
      final log = <String>[];
      final controller = await joined(bundleJson(modules: {'proximity': {}}), module, log);
      record(module);

      // A crowded room on iOS: a wake on every detection.
      for (var i = 0; i < 10; i++) {
        module.startedWith!.requestSync();
      }
      await Future<void>.delayed(Duration.zero);

      expect(log.where((path) => path.endsWith('/observations')), hasLength(1));
      expect(await controller.syncThrottled(), isFalse, reason: 'still inside the floor');
      controller.dispose();
    });

    test('a study may ask for less frequent uploads and get them', () async {
      final module = _FakeModule('proximity');
      final controller = await joined(
        bundleJson(modules: {'proximity': {}}, sync: {'min_interval_seconds': 3600}),
        module,
        [],
      );

      // `sync.min_interval_seconds` has been in the bundle contract since before anything read it.
      expect(controller.effectiveSyncFloor, const Duration(hours: 1));
      controller.dispose();
    });

    test('a study cannot ask for more frequent uploads than the platform allows', () async {
      final module = _FakeModule('proximity');
      final controller = await joined(
        bundleJson(modules: {'proximity': {}}, sync: {'min_interval_seconds': 60}),
        module,
        [],
      );

      // How hard a phone may be worked is not the study's call.
      expect(controller.effectiveSyncFloor, StudyController.syncFloor);
      controller.dispose();
    });

    test('a study that says nothing gets the platform floor', () async {
      final module = _FakeModule('proximity');
      final controller = await joined(bundleJson(modules: {'proximity': {}}), module, []);

      expect(controller.effectiveSyncFloor, StudyController.syncFloor);
      controller.dispose();
    });
  });

  group('resuming', () {
    test('a study joined in an earlier session starts collecting again', () async {
      final bundle = bundleJson(modules: {'proximity': {}});
      await binaryWith([_FakeModule('proximity')], serverServing(bundle)).join('JOIN-1234');

      final afterRestart = _FakeModule('proximity');
      final controller = binaryWith([afterRestart], serverServing(bundle));
      await controller.initialize();

      expect(controller.state, StudyState.collecting);
      expect(afterRestart.startedWith, isNotNull);
      expect(controller.enrollment!.studyId, _studyId);
    });
  });

  group('withdrawing', () {
    test('stops collection and leaves nothing on the device', () async {
      final module = _FakeModule('proximity');
      final bundle = bundleJson(modules: {'proximity': {}});
      final controller = binaryWith([module], serverServing(bundle));
      await controller.join('JOIN-1234');

      module.startedWith!.record(
        schemaUri: 'https://schemas.epidemica.info/x/1.0.0.json',
        observedAt: DateTime.utc(2026, 9, 2, 12),
        payload: const {'a': 1},
      );
      expect(controller.pendingObservations, 1);
      final pseudonymBefore = controller.subject;

      await controller.withdraw();

      expect(module.stops, 1);
      expect(controller.state, StudyState.notEnrolled);
      expect(controller.enrollment, isNull);
      expect(controller.pendingObservations, 0);
      expect(await secrets.read(TokenStore.storageKey), isNull);
      expect(db.db.select('SELECT * FROM meta'), isEmpty);
      // A retained pseudonym would let a later enrollment be linked to this one, which is
      // precisely what withdrawing is meant to prevent.
      expect(Identity(db).subject, isNot(pseudonymBefore));
    });

    test('queued observations are destroyed, not left to upload later', () async {
      final module = _FakeModule('proximity');
      final controller = binaryWith([
        module,
      ], serverServing(bundleJson(modules: {'proximity': {}})));
      await controller.join('JOIN-1234');
      for (var i = 0; i < 10; i++) {
        module.startedWith!.record(
          schemaUri: 'https://schemas.epidemica.info/x/1.0.0.json',
          observedAt: DateTime.utc(2026, 9, 2, 12),
          payload: {'i': i},
        );
      }

      await controller.withdraw();

      expect(db.db.select('SELECT * FROM outbox'), isEmpty);
      expect(db.db.select('SELECT * FROM dead_letter'), isEmpty);
    });
  });

  group('a study gets only what its bundle asks for', () {
    test('coverage reporting can be switched off entirely', () async {
      final module = _FakeModule('proximity');
      final controller = binaryWith([
        module,
      ], serverServing(bundleJson(modules: {'proximity': {}}, health: {'enabled': false})));

      await controller.join('JOIN-1234');
      await Future<void>.delayed(Duration.zero);

      // A Tier 1 study that has no use for coverage must not be made to pay for it.
      expect(db.db.select("SELECT * FROM outbox WHERE schema_uri LIKE '%module_status%'"), isEmpty);
    });

    test('a study with no twin never has state computed for it', () async {
      final controller = binaryWith([
        _FakeModule('proximity'),
      ], serverServing(bundleJson(modules: {'proximity': {}})));

      await controller.join('JOIN-1234');

      // Absent, not disabled: nothing on either side is asked to opt out of a simulation.
      expect(controller.enrollment!.bundle.twin, isNull);
    });
  });

  group('what the modules are doing right now', () {
    test('is empty until asked', () async {
      final proximity = _FakeModule('proximity');
      final controller = binaryWith([
        proximity,
      ], serverServing(bundleJson(modules: {'proximity': {}})));
      await controller.join('JOIN-1234');

      expect(controller.moduleStatus, isEmpty);
    });

    test('reports the radio going off without waiting for the server', () async {
      final proximity = _FakeModule('proximity');
      final controller = binaryWith([
        proximity,
      ], serverServing(bundleJson(modules: {'proximity': {}})));
      await controller.join('JOIN-1234');

      await controller.refreshModuleStatus();
      expect(controller.moduleStatus['proximity']!.isSensing, isTrue);

      // A participant who turns Bluetooth off should not have to wait for a tick to be told what
      // their own phone is doing.
      proximity.reported = const ModuleStatus(ModuleState.radioOff, detail: 'bluetooth');
      await controller.refreshModuleStatus();

      expect(controller.moduleStatus['proximity']!.isSensing, isFalse);
      expect(controller.moduleStatus['proximity']!.detail, 'bluetooth');
    });

    test('notifies only when something changed', () async {
      final proximity = _FakeModule('proximity');
      final controller = binaryWith([
        proximity,
      ], serverServing(bundleJson(modules: {'proximity': {}})));
      await controller.join('JOIN-1234');

      await controller.refreshModuleStatus();

      var notifications = 0;
      controller.addListener(() => notifications++);

      // Polled every few seconds, so an unchanged answer must not rebuild the screen.
      await controller.refreshModuleStatus();
      await controller.refreshModuleStatus();
      expect(notifications, 0);

      proximity.reported = const ModuleStatus(ModuleState.radioOff);
      await controller.refreshModuleStatus();
      expect(notifications, 1);
    });

    test('a module that cannot answer is not reported as sensing', () async {
      final proximity = _FakeModule('proximity');
      final controller = binaryWith([
        proximity,
      ], serverServing(bundleJson(modules: {'proximity': {}})));
      await controller.join('JOIN-1234');

      proximity.throws = StateError('channel gone');
      await controller.refreshModuleStatus();

      expect(controller.moduleStatus['proximity']!.isSensing, isFalse);
    });

    test('withdrawing forgets it', () async {
      final proximity = _FakeModule('proximity');
      final controller = binaryWith([
        proximity,
      ], serverServing(bundleJson(modules: {'proximity': {}})));
      await controller.join('JOIN-1234');
      await controller.refreshModuleStatus();
      expect(controller.moduleStatus, isNotEmpty);

      await controller.withdraw();

      expect(controller.moduleStatus, isEmpty);
    });
  });
}
