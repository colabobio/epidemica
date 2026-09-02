import 'dart:convert';
import 'dart:io';

import 'package:epidemica_core/epidemica_core.dart';
import 'package:epidemica_template/src/modules/embedded_module.dart';
import 'package:epidemica_template/src/study_controller.dart';
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

  @override
  Future<void> start(ModuleContext context) async => startedWith = context;

  @override
  Future<void> stop() async => stops++;
}

const _bundleUrl = 'https://example.test/bundles/study.json';
const _studyId = 'c0badf00-1111-4222-8333-444455556666';

String bundleJson({
  required Map<String, Object?> modules,
  String title = 'Contact logging pilot',
}) => jsonEncode({
  'bundle_version': '1.0',
  'study_id': _studyId,
  'title': title,
  'modules': modules,
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

  http.Client serverServing(String bundle, {int enrollStatus = 201}) =>
      MockClient((request) async {
        if (request.url.toString() == _bundleUrl) return http.Response(bundle, 200);
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
  StudyController binaryWith(List<EmbeddedModule> modules, http.Client client) =>
      StudyController(
        baseUri: Uri.parse('https://example.test/v1/'),
        modules: modules,
        db: db,
        secrets: secrets,
        platform: 'android',
        httpClient: client,
      );

  group('the same binary, different bundles', () {
    test('activates only the modules the study names', () async {
      final proximity = _FakeModule('proximity');
      final instruments = _FakeModule('instruments');

      await binaryWith([proximity, instruments], serverServing(
        bundleJson(modules: {'proximity': {'on_device': {'max_episode_seconds': 600}}}),
      )).join('JOIN-1234');

      expect(proximity.startedWith, isNotNull);
      expect(instruments.startedWith, isNull);
      expect(
        proximity.startedWith!.config,
        {'on_device': {'max_episode_seconds': 600}},
        reason: 'a module receives its own block, not the whole bundle',
      );
    });

    test('a different bundle collects a different module, with no rebuild', () async {
      final proximity = _FakeModule('proximity');
      final instruments = _FakeModule('instruments');

      // Same module set, same construction, same binary.
      await binaryWith([proximity, instruments], serverServing(
        bundleJson(modules: {'instruments': {'schedule': 'daily'}}),
      )).join('JOIN-5678');

      expect(instruments.startedWith, isNotNull);
      expect(proximity.startedWith, isNull);
      expect(instruments.startedWith!.config, {'schedule': 'daily'});
    });

    test('a bundle naming two modules starts both', () async {
      final proximity = _FakeModule('proximity');
      final instruments = _FakeModule('instruments');

      final controller = binaryWith([proximity, instruments], serverServing(
        bundleJson(modules: {'proximity': {}, 'instruments': {}}),
      ));
      await controller.join('JOIN-1234');

      expect(controller.runningModules, {'proximity', 'instruments'});
      expect(controller.state, StudyState.collecting);
    });
  });

  group('a study this binary cannot service', () {
    test('is refused with a message a participant can act on', () async {
      final controller = binaryWith([_FakeModule('proximity')], serverServing(
        bundleJson(modules: {'proximity': {}, 'biosensing': {}}),
      ));

      await controller.join('JOIN-1234');

      expect(controller.state, StudyState.refused);
      expect(controller.message, contains('newer version of the app'));
      expect(controller.message, contains('biosensing'));
    });

    test('leaves the participant enrolled in nothing at all', () async {
      final module = _FakeModule('proximity');
      final controller = binaryWith([module], serverServing(
        bundleJson(modules: {'biosensing': {}}),
      ));

      await controller.join('JOIN-1234');

      expect(controller.enrollment, isNull);
      expect(module.startedWith, isNull);
      // Enrolled-but-collecting-nothing looks healthy and is only discovered at analysis.
      expect(controller.pendingObservations, 0);
      await controller.initialize();
      expect(controller.state, StudyState.notEnrolled);
    });

    test('an unknown code is not blamed on the participant twice', () async {
      final controller = binaryWith(
        [_FakeModule('proximity')],
        serverServing(bundleJson(modules: {'proximity': {}}), enrollStatus: 404),
      );

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
      final controller = binaryWith([module], serverServing(
        bundleJson(modules: {'proximity': {}}),
      ));
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
      final controller = binaryWith([module], serverServing(
        bundleJson(modules: {'proximity': {}}),
      ));
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
}
