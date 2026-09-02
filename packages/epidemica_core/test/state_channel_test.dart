import 'dart:convert';
import 'dart:io';

import 'package:epidemica_core/epidemica_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Tokens implements AccessTokenSource {
  @override
  Future<String> accessToken() async => 'access-1';

  @override
  Future<void> refresh() async {}
}

const _studyId = 'c0badf00-1111-4222-8333-444455556666';
const _subject = 'c9e2f1a0-6b3d-4c88-9a71-2f3e4d5c6b7a';
const _stateUri = 'https://schemas.epidemica.info/state/epigame/1.0.0.json';

String document({
  required int revision,
  String asOf = '2026-09-04T03:00:00Z',
  Map<String, Object?> state = const {'points': 11},
  String subject = _subject,
}) => jsonEncode({
  'state_version': '1.0',
  'study_id': _studyId,
  'subject': subject,
  'state_uri': _stateUri,
  'revision': revision,
  'as_of': asOf,
  'state': state,
});

void main() {
  late Directory dir;
  late EpidemicaDatabase db;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('epidemica_state');
    db = EpidemicaDatabase.open('${dir.path}/epidemica.db');
  });

  tearDown(() {
    db.close();
    dir.deleteSync(recursive: true);
  });

  StateChannel channelOn(http.Client client) => StateChannel(
    baseUri: Uri.parse('https://example.test/v1/'),
    db: db,
    tokens: _Tokens(),
    httpClient: client,
  );

  group('fetching', () {
    test('parses a document and keeps the server\'s as_of', () async {
      final channel = channelOn(
        MockClient((_) async => http.Response(document(revision: 4), 200)),
      );

      final state = await channel.refresh();

      expect(state!.revision, 4);
      expect(state.stateUri, _stateUri);
      expect(state.asOf, DateTime.utc(2026, 9, 4, 3));
      expect(state.state, {'points': 11});
    });

    test('state is opaque to core', () async {
      // Whatever a study puts here passes through untouched; core knowing otherwise would be core
      // knowing about a study.
      final channel = channelOn(
        MockClient(
          (_) async => http.Response(
            document(revision: 1, state: {'streak_days': 12, 'nested': {'a': 1}}),
            200,
          ),
        ),
      );

      final state = await channel.refresh();

      expect(state!.state, {'streak_days': 12, 'nested': {'a': 1}});
    });

    test('nothing computed yet is null, not an invented state', () async {
      final channel = channelOn(MockClient((_) async => http.Response('{}', 404)));

      // An invented "you are healthy" is indistinguishable from a measured one.
      expect(await channel.refresh(), isNull);
      expect(channel.current(), isNull);
    });

    test('an unsupported envelope version is refused rather than half-read', () async {
      final channel = channelOn(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'state_version': '2.0',
              'study_id': _studyId,
              'subject': _subject,
              'state_uri': _stateUri,
              'revision': 1,
              'as_of': '2026-09-04T03:00:00Z',
              'state': {},
            }),
            200,
          ),
        ),
      );

      await expectLater(channel.refresh(), throwsA(isA<FormatException>()));
    });
  });

  group('revisions', () {
    test('an older response never overwrites a newer one', () async {
      var call = 0;
      final channel = channelOn(
        MockClient((_) async {
          call++;
          // Out-of-order delivery is normal on a bad connection.
          return http.Response(document(revision: call == 1 ? 9 : 3), 200);
        }),
      );

      expect((await channel.refresh())!.revision, 9);
      expect((await channel.refresh())!.revision, 9, reason: 'revision 3 arrived late');
      expect(channel.current()!.state, {'points': 11});
    });

    test('an equal revision is not rewritten', () async {
      final channel = channelOn(
        MockClient((_) async => http.Response(document(revision: 5), 200)),
      );

      await channel.refresh();
      expect((await channel.refresh())!.revision, 5);
    });
  });

  group('caching', () {
    test('survives a restart with the original as_of', () async {
      final channel = channelOn(
        MockClient((_) async => http.Response(document(revision: 4), 200)),
      );
      await channel.refresh();
      db.close();

      final reopened = EpidemicaDatabase.open('${dir.path}/epidemica.db');
      final restored = StateChannel(
        baseUri: Uri.parse('https://example.test/v1/'),
        db: reopened,
        tokens: _Tokens(),
        httpClient: MockClient((_) async => throw const SocketException('offline')),
      );

      final cached = restored.current();
      expect(cached!.revision, 4);
      // Never re-stamped on read: a day-old computation must still look a day old.
      expect(cached.asOf, DateTime.utc(2026, 9, 4, 3));
      reopened.close();
      db = EpidemicaDatabase.open('${dir.path}/epidemica.db');
    });

    test('offline keeps the cached document and says why it could not refresh', () async {
      final online = channelOn(
        MockClient((_) async => http.Response(document(revision: 4), 200)),
      );
      await online.refresh();

      final offline = channelOn(
        MockClient((_) async => throw const SocketException('offline')),
      );

      expect(offline.current()!.revision, 4);
      await expectLater(offline.refresh(), throwsA(isA<IngestTransient>()));
      expect(offline.current()!.revision, 4, reason: 'a failed refresh must not clear the cache');
    });

    test('a 404 after a document has been seen keeps it', () async {
      final channel = channelOn(
        MockClient((_) async => http.Response(document(revision: 4), 200)),
      );
      await channel.refresh();

      final gone = channelOn(MockClient((_) async => http.Response('{}', 404)));

      // Far more likely a routing or deployment problem than a real deletion.
      expect((await gone.refresh())!.revision, 4);
    });

    test('a document belonging to a previous enrolment is not shown', () async {
      final channel = channelOn(
        MockClient((_) async => http.Response(document(revision: 4), 200)),
      );
      await channel.refresh();

      expect(channel.current(expectedSubject: _subject), isNotNull);
      expect(channel.current(expectedSubject: 'someone-else-0001'), isNull);
    });

    test('clearing removes it', () async {
      final channel = channelOn(
        MockClient((_) async => http.Response(document(revision: 4), 200)),
      );
      await channel.refresh();

      channel.clear();

      expect(channel.current(), isNull);
      expect(db.readMeta('participant_state'), isNull);
    });
  });

  group('staleness', () {
    test('age is measured from the computation, not the fetch', () async {
      final channel = channelOn(
        MockClient(
          (_) async => http.Response(document(revision: 1, asOf: '2026-09-04T03:00:00Z'), 200),
        ),
      );

      final state = await channel.refresh();

      expect(
        state!.ageAt(DateTime.utc(2026, 9, 4, 15)),
        const Duration(hours: 12),
      );
    });
  });

  group('failures', () {
    test('an unauthorised fetch is distinguishable from an empty one', () async {
      final channel = channelOn(MockClient((_) async => http.Response('{}', 401)));

      await expectLater(channel.refresh(), throwsA(isA<IngestUnauthorized>()));
    });

    test('a server error is transient, not a missing state', () async {
      final channel = channelOn(MockClient((_) async => http.Response('boom', 503)));

      await expectLater(channel.refresh(), throwsA(isA<IngestTransient>()));
    });
  });
}
