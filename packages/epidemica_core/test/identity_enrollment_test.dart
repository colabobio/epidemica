import 'dart:convert';
import 'dart:io';

import 'package:epidemica_core/src/db/database.dart';
import 'package:epidemica_core/src/enrollment.dart';
import 'package:epidemica_core/src/identity.dart';
import 'package:epidemica_core/src/protocol_bundle.dart';
import 'package:epidemica_core/src/tokens.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _bundleUrl = 'https://example.test/bundles/contactlog.json';

String _bundleJson({List<String> modules = const ['proximity']}) => jsonEncode({
  'bundle_version': '1.0',
  'study_id': '11111111-2222-4333-8444-555555555555',
  'title': 'Contact logging pilot',
  'modules': {
    for (final m in modules)
      m: m == 'proximity' ? {'on_device': {'max_episode_seconds': 900}} : {},
  },
});

void main() {
  late Directory dir;
  late EpidemicaDatabase db;
  late Identity identity;
  late InMemorySecretStore secrets;
  late TokenStore tokens;

  final baseUri = Uri.parse('https://example.test/v1/');
  final now = DateTime.utc(2026, 9, 2, 12);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('epidemica_enroll');
    db = EpidemicaDatabase.open('${dir.path}/epidemica.db');
    identity = Identity(db);
    secrets = InMemorySecretStore();
    tokens = TokenStore(baseUri: baseUri, secrets: secrets, now: () => now);
  });

  tearDown(() {
    db.close();
    dir.deleteSync(recursive: true);
  });

  http.Client clientFor({
    int enrollStatus = 201,
    String? bundleBody,
    int bundleStatus = 200,
    String? protocolHash,
  }) {
    final body = bundleBody ?? _bundleJson();
    return MockClient((request) async {
      if (request.url.toString() == _bundleUrl) {
        return http.Response(body, bundleStatus);
      }
      if (enrollStatus != 201) return http.Response('{}', enrollStatus);
      return http.Response(
        jsonEncode({
          'subject': identity.subject,
          'study_id': '11111111-2222-4333-8444-555555555555',
          'arm': 'control',
          'protocol_hash': protocolHash ?? ProtocolBundle.hashOf(utf8.encode(body)),
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
  }

  EnrollmentService serviceWith(
    http.Client client, {
    Set<String> modules = const {'proximity'},
  }) => EnrollmentService(
    baseUri: baseUri,
    db: db,
    identity: identity,
    tokens: tokens,
    registry: ModuleRegistry(modules),
    platform: 'android',
    httpClient: client,
    now: () => now,
  );

  group('identity', () {
    test('is generated once and is stable across restarts', () {
      final subject = identity.subject;
      final deviceId = identity.deviceId;

      expect(identity.subject, subject);
      expect(Identity(db).subject, subject, reason: 'a new instance must not regenerate');

      db.close();
      final reopened = EpidemicaDatabase.open('${dir.path}/epidemica.db');
      expect(Identity(reopened).subject, subject);
      expect(Identity(reopened).deviceId, deviceId);
      reopened.close();
      db = EpidemicaDatabase.open('${dir.path}/epidemica.db');
    });

    test('the pseudonym and the device id are different values', () {
      expect(identity.subject, isNot(identity.deviceId));
    });

    test('the pseudonym satisfies the envelope character guard', () {
      // The class rejects '@', '.' and whitespace, so an email cannot be submitted by accident.
      expect(identity.subject, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
      expect(identity.subject.length, greaterThanOrEqualTo(8));
    });

    test('generated pseudonyms do not repeat', () {
      final generated = {for (var i = 0; i < 500; i++) Identity.newUuidV4()};
      expect(generated.length, 500);
    });

    test('isEstablished reflects whether identity has been created', () {
      expect(identity.isEstablished, isFalse);
      identity.subject;
      identity.deviceId;
      expect(identity.isEstablished, isTrue);
    });
  });

  group('enrollment', () {
    test('exchanges a join code for tokens and a bundle', () async {
      final enrollment = await serviceWith(clientFor()).enroll('JOIN-1234');

      expect(enrollment.studyId, '11111111-2222-4333-8444-555555555555');
      expect(enrollment.arm, 'control');
      expect(enrollment.bundle.requiredModules, ['proximity']);
      expect((await tokens.read())!.accessToken, 'access-1');
    });

    test('tokens are written to secure storage, not the database', () async {
      await serviceWith(clientFor()).enroll('JOIN-1234');

      expect(secrets.values.keys, contains(TokenStore.storageKey));
      final everythingInTheDatabase = db.db
          .select('SELECT value FROM meta')
          .map((r) => r['value'] as String)
          .join('\n');
      expect(everythingInTheDatabase, isNot(contains('access-1')));
      expect(everythingInTheDatabase, isNot(contains('refresh-1')));
    });

    test('survives a restart', () async {
      await serviceWith(clientFor()).enroll('JOIN-1234');

      final restored = serviceWith(clientFor()).current();

      expect(restored, isNotNull);
      expect(restored!.studyId, '11111111-2222-4333-8444-555555555555');
      expect(restored.protocolHash, startsWith('sha256:'));
      expect(restored.bundle.configFor('proximity'), isNotEmpty);
    });

    test('there is no enrollment before one is made', () {
      expect(serviceWith(clientFor()).current(), isNull);
    });

    test('an unknown join code is not distinguishable from a closed study', () async {
      await expectLater(
        serviceWith(clientFor(enrollStatus: 404)).enroll('NOPE'),
        throwsA(
          isA<EnrollmentException>().having(
            (e) => e.failure,
            'failure',
            EnrollmentFailure.unknownJoinCode,
          ),
        ),
      );
    });

    test('a pseudonym already bound to another device is reported as such', () async {
      await expectLater(
        serviceWith(clientFor(enrollStatus: 409)).enroll('JOIN-1234'),
        throwsA(
          isA<EnrollmentException>().having(
            (e) => e.failure,
            'failure',
            EnrollmentFailure.alreadyEnrolled,
          ),
        ),
      );
    });
  });

  group('bundle satisfiability', () {
    test('a study needing a module this build lacks fails loudly', () async {
      final client = clientFor(
        bundleBody: _bundleJson(modules: ['proximity', 'biosensing']),
      );

      await expectLater(
        serviceWith(client, modules: {'proximity'}).enroll('JOIN-1234'),
        throwsA(
          isA<EnrollmentException>()
              .having((e) => e.failure, 'failure', EnrollmentFailure.unsupportedModules)
              .having((e) => e.missingModules, 'missing', ['biosensing']),
        ),
      );
    });

    test('a failed check leaves nothing behind to act on', () async {
      final client = clientFor(bundleBody: _bundleJson(modules: ['instruments']));

      await expectLater(
        serviceWith(client, modules: {'proximity'}).enroll('JOIN-1234'),
        throwsA(isA<EnrollmentException>()),
      );

      // Enrolling anyway is the worst available failure: it looks successful and is only
      // discovered at analysis, when the collection window has passed.
      expect(serviceWith(client).current(), isNull);
      expect(await tokens.read(), isNull);
    });

    test('a build with more modules than the study needs is fine', () async {
      final enrollment = await serviceWith(
        clientFor(),
        modules: {'proximity', 'instruments', 'location'},
      ).enroll('JOIN-1234');

      expect(enrollment.bundle.requiredModules, ['proximity']);
    });

    test('the registry reports every missing module, sorted', () {
      const registry = ModuleRegistry({'proximity'});
      final bundle = ProtocolBundle.parse(
        utf8.encode(_bundleJson(modules: ['reach', 'proximity', 'biosensing'])),
      );

      expect(registry.missingFor(bundle), ['biosensing', 'reach']);
      expect(registry.canService(bundle), isFalse);
    });
  });

  group('bundle integrity', () {
    test('a bundle that does not match the promised hash is refused', () async {
      final client = clientFor(protocolHash: 'sha256:${'0' * 64}');

      await expectLater(
        serviceWith(client).enroll('JOIN-1234'),
        throwsA(
          isA<EnrollmentException>().having(
            (e) => e.failure,
            'failure',
            EnrollmentFailure.bundleHashMismatch,
          ),
        ),
      );
    });

    test('an unreachable bundle is reported rather than assumed empty', () async {
      await expectLater(
        serviceWith(clientFor(bundleStatus: 500)).enroll('JOIN-1234'),
        throwsA(
          isA<EnrollmentException>().having(
            (e) => e.failure,
            'failure',
            EnrollmentFailure.bundleUnavailable,
          ),
        ),
      );
    });

    test('the hash covers the served bytes, not a re-encoding', () {
      // Two documents that parse identically but serialise differently must not share a hash;
      // the hash has to identify what was actually served.
      final a = utf8.encode('{"study_id":"s","modules":{}}');
      final b = utf8.encode('{"modules":{},"study_id":"s"}');
      expect(ProtocolBundle.hashOf(a), isNot(ProtocolBundle.hashOf(b)));
    });
  });

  group('tokens', () {
    test('a stored access token is returned while it is fresh', () async {
      await tokens.save(
        StudyTokens(accessToken: 'a1', expiresAt: now.add(const Duration(hours: 1))),
      );
      expect(await tokens.accessToken(), 'a1');
    });

    test('an expiring token is refreshed before it is used', () async {
      var refreshCalls = 0;
      final store = TokenStore(
        baseUri: baseUri,
        secrets: secrets,
        now: () => now,
        httpClient: MockClient((request) async {
          refreshCalls++;
          return http.Response(
            jsonEncode({'access_token': 'a2', 'token_type': 'Bearer', 'expires_in': 3600}),
            200,
          );
        }),
      );
      await store.save(
        // Inside the refresh margin, so it is treated as already stale.
        StudyTokens(
          accessToken: 'a1',
          expiresAt: now.add(const Duration(seconds: 30)),
          refreshToken: 'r1',
        ),
      );

      expect(await store.accessToken(), 'a2');
      expect(refreshCalls, 1);
      expect((await store.read())!.refreshToken, 'r1', reason: 'kept when the server omits one');
    });

    test('a revoked refresh token clears storage and demands re-enrollment', () async {
      final store = TokenStore(
        baseUri: baseUri,
        secrets: secrets,
        now: () => now,
        httpClient: MockClient((_) async => http.Response('{}', 401)),
      );
      await store.save(
        StudyTokens(accessToken: 'a1', expiresAt: now, refreshToken: 'r1'),
      );

      await expectLater(store.refresh(), throwsA(isA<ReEnrollmentRequired>()));
      expect(await store.read(), isNull, reason: 'a dead token would only produce a retry loop');
    });

    test('asking for a token with nothing stored demands re-enrollment', () async {
      await expectLater(tokens.accessToken(), throwsA(isA<ReEnrollmentRequired>()));
    });
  });
}
