import 'dart:convert';
import 'dart:io';

import 'package:epidemica_core/src/clock.dart';
import 'package:epidemica_core/src/db/database.dart';
import 'package:epidemica_core/src/outbox.dart';
import 'package:epidemica_core/src/sync/backoff.dart';
import 'package:epidemica_core/src/sync/ingest_client.dart';
import 'package:epidemica_core/src/sync/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _StaticTokens implements AccessTokenSource {
  int refreshes = 0;
  String token = 'access-1';

  @override
  Future<String> accessToken() async => token;

  @override
  Future<void> refresh() async {
    refreshes++;
    token = 'access-2';
  }
}

/// A clock the test advances when the request is handled, so timing assertions do not depend on
/// how many times the service happens to read the time.
class _FakeClock {
  _FakeClock(this._value);

  DateTime _value;

  DateTime now() => _value;

  void advance(Duration by) => _value = _value.add(by);
}

/// A scripted server. Each entry handles one request, in order.
class _Server {
  _Server(this.handlers);

  final List<http.Response Function(http.Request request)> handlers;
  final List<List<Map<String, Object?>>> receivedBatches = [];
  final List<String> authHeaders = [];
  int calls = 0;

  http.Client get client => MockClient((request) async {
    authHeaders.add(request.headers['authorization'] ?? '');
    if (request.headers['content-encoding'] == 'gzip') {
      final decoded = jsonDecode(utf8.decode(gzip.decode(request.bodyBytes)));
      receivedBatches.add([
        for (final o in (decoded as Map)['observations'] as List)
          (o as Map).cast<String, Object?>(),
      ]);
    }
    final handler = handlers[calls.clamp(0, handlers.length - 1)];
    calls++;
    return handler(request);
  });
}

http.Response _ok({
  required int received,
  int? accepted,
  int duplicate = 0,
  int quarantined = 0,
  int rejected = 0,
  List<Map<String, Object?>> exceptions = const [],
  String serverTime = '2026-09-02T12:00:00Z',
}) => http.Response(
  jsonEncode({
    'received': received,
    'accepted': accepted ?? received - duplicate - quarantined - rejected,
    'duplicate': duplicate,
    'quarantined': quarantined,
    'rejected': rejected,
    'exceptions': exceptions,
    'server_time': serverTime,
  }),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  late Directory dir;
  late EpidemicaDatabase db;
  late Outbox outbox;
  late DeviceClock clock;
  late _StaticTokens tokens;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('epidemica_sync');
    db = EpidemicaDatabase.open('${dir.path}/epidemica.db');
    outbox = Outbox(db);
    clock = DeviceClock(db);
    tokens = _StaticTokens();
  });

  tearDown(() {
    db.close();
    dir.deleteSync(recursive: true);
  });

  void record({int count = 1, String module = 'proximity'}) {
    for (var i = 0; i < count; i++) {
      outbox.record(
        studyId: 'study-1',
        protocolHash: 'sha256:${'a' * 64}',
        subject: 'subject-0001',
        deviceId: 'device-1',
        module: module,
        schemaUri: 'https://schemas.epidemica.info/x/1.0.0.json',
        observedAt: DateTime.utc(2026, 9, 2, 11, i % 60),
        payload: {'i': i},
      );
    }
  }

  SyncService serviceFor(
    _Server server, {
    int batchSize = Outbox.maxBatchSize,
    DateTime Function()? now,
  }) => SyncService(
    outbox: outbox,
    clock: clock,
    batchSize: batchSize,
    now: now,
    client: IngestClient(
      baseUri: Uri.parse('https://example.test/v1/'),
      tokens: tokens,
      httpClient: server.client,
    ),
  );

  group('a clean batch', () {
    test('empties the outbox and gzips the body', () async {
      record(count: 3);
      final server = _Server([(_) => _ok(received: 3)]);

      final report = await serviceFor(server).syncOnce();

      expect(report.delivered, 3);
      expect(report.isComplete, isTrue);
      expect(outbox.pendingCount(), 0);
      expect(server.receivedBatches.single.length, 3, reason: 'body must be gzipped JSON');
      expect(server.authHeaders.single, 'Bearer access-1');
    });

    test('sends full envelopes in sequence order', () async {
      record(count: 2);
      final server = _Server([(_) => _ok(received: 2)]);

      await serviceFor(server).syncOnce();

      final sent = server.receivedBatches.single;
      expect(sent.map((e) => e['seq']), [1, 2]);
      expect(sent.first['study_id'], 'study-1');
      expect(sent.first['module'], 'proximity');
      expect(sent.first.containsKey('clock_offset_ms'), isTrue);
    });

    test('chunks to the batch size', () async {
      record(count: 5);
      final server = _Server([(_) => _ok(received: 2), (_) => _ok(received: 2), (_) => _ok(received: 1)]);

      final report = await serviceFor(server, batchSize: 2).syncOnce();

      expect(report.batches, 3);
      expect(report.delivered, 5);
      expect(outbox.pendingCount(), 0);
    });
  });

  group('outcomes', () {
    test('accepted observations are removed even though the server never names them', () async {
      // The contract omits successes from `exceptions`. A client that deleted only what was
      // listed would keep every accepted row and resend it forever.
      record(count: 3);
      final server = _Server([
        (_) => _ok(
          received: 3,
          duplicate: 1,
          exceptions: [
            {'seq': 2, 'index': 1, 'status': 'duplicate'},
          ],
        ),
      ]);

      final report = await serviceFor(server).syncOnce();

      expect(report.delivered, 3);
      expect(report.duplicates, 1);
      expect(outbox.pendingCount(), 0);
    });

    test('a resent batch comes back all duplicates and still drains', () async {
      record(count: 2);
      final server = _Server([
        (_) => _ok(
          received: 2,
          duplicate: 2,
          exceptions: [
            {'seq': 1, 'index': 0, 'status': 'duplicate'},
            {'seq': 2, 'index': 1, 'status': 'duplicate'},
          ],
        ),
      ]);

      final report = await serviceFor(server).syncOnce();

      expect(report.duplicates, 2);
      expect(report.deadLettered, 0);
      expect(outbox.pendingCount(), 0);
    });

    test('quarantined counts as delivered, because the server stored it', () async {
      record(count: 2);
      final server = _Server([
        (_) => _ok(
          received: 2,
          quarantined: 1,
          exceptions: [
            {
              'seq': 1,
              'index': 0,
              'status': 'quarantined',
              'reason': 'unknown_payload_schema',
            },
          ],
        ),
      ]);

      final report = await serviceFor(server).syncOnce();

      expect(report.quarantined, 1);
      expect(outbox.pendingCount(), 0, reason: 'retrying would only re-quarantine it');
      expect(outbox.deadLetters(), isEmpty);
    });

    test('rejected observations are dead-lettered, not deleted and not retried', () async {
      record(count: 2);
      final server = _Server([
        (_) => _ok(
          received: 2,
          rejected: 1,
          exceptions: [
            {
              'seq': 1,
              'index': 0,
              'status': 'rejected',
              'reason': 'payload_invalid',
              'detail': 'band_seconds.immediate: must be >= 0',
            },
          ],
        ),
      ]);

      final report = await serviceFor(server).syncOnce();

      expect(report.deadLettered, 1);
      expect(report.delivered, 1);
      expect(outbox.pendingCount(), 0);

      final parked = outbox.deadLetters().single;
      expect(parked.seq, 1);
      expect(parked.reason, 'payloadInvalid');
      expect(parked.detail, contains('band_seconds'));
    });

    test('an outcome with an unreadable seq is located by index', () async {
      record(count: 2);
      final server = _Server([
        (_) => _ok(
          received: 2,
          rejected: 1,
          exceptions: [
            {'seq': null, 'index': 1, 'status': 'rejected', 'reason': 'unparseable'},
          ],
        ),
      ]);

      await serviceFor(server).syncOnce();

      expect(outbox.deadLetters().single.seq, 2);
    });
  });

  group('failures', () {
    test('429 releases the claim and reports the server Retry-After', () async {
      record(count: 2);
      final server = _Server([
        (_) => http.Response('{}', 429, headers: {'retry-after': '120'}),
      ]);

      final report = await serviceFor(server).syncOnce();

      expect(report.retryAfter, const Duration(seconds: 120));
      expect(report.remaining, 2, reason: 'nothing may be lost to a rate limit');
      expect(outbox.unclaimedCount(), 2, reason: 'the claim must be released for the retry');
    });

    test('5xx backs off and keeps the observations', () async {
      record(count: 2);
      final server = _Server([(_) => http.Response('boom', 503)]);

      final report = await serviceFor(server).syncOnce();

      expect(report.error, isA<IngestTransient>());
      expect(report.retryAfter, isNotNull);
      expect(outbox.unclaimedCount(), 2);
    });

    test('a transport failure loses nothing', () async {
      record(count: 2);
      final server = _Server([(_) => throw const SocketException('offline')]);

      final report = await serviceFor(server).syncOnce();

      expect(report.error, isA<IngestTransient>());
      expect(outbox.unclaimedCount(), 2);
    });

    test('413 halves the batch and carries on', () async {
      record(count: 4);
      var call = 0;
      final server = _Server([
        (_) {
          call++;
          return call == 1 ? http.Response('too big', 413) : _ok(received: 2);
        },
      ]);

      final report = await serviceFor(server, batchSize: 4).syncOnce();

      expect(report.delivered, 4);
      expect(outbox.pendingCount(), 0);
      expect(server.receivedBatches.last.length, 2);
    });

    test('401 refreshes the token once and retries', () async {
      record(count: 1);
      var call = 0;
      final server = _Server([
        (_) {
          call++;
          return call == 1 ? http.Response('{}', 401) : _ok(received: 1);
        },
      ]);

      final report = await serviceFor(server).syncOnce();

      expect(tokens.refreshes, 1);
      expect(report.delivered, 1);
      expect(server.authHeaders, ['Bearer access-1', 'Bearer access-2']);
    });

    test('a 401 that survives a refresh stops rather than looping', () async {
      record(count: 1);
      final server = _Server([(_) => http.Response('{}', 401)]);

      final report = await serviceFor(server).syncOnce();

      expect(report.error, isA<IngestUnauthorized>());
      expect(tokens.refreshes, 1);
      expect(outbox.unclaimedCount(), 1);
    });

    test('24 hours offline loses nothing and uploads on reconnect', () async {
      record(count: 500);
      final offline = _Server([(_) => throw const SocketException('offline')]);

      for (var hour = 0; hour < 24; hour++) {
        final report = await serviceFor(offline).syncOnce();
        expect(report.delivered, 0);
      }
      expect(outbox.pendingCount(), 500);

      final online = _Server([(_) => _ok(received: 500)]);
      final report = await serviceFor(online).syncOnce();

      expect(report.delivered, 500);
      expect(outbox.pendingCount(), 0);
    });
  });

  group('clock', () {
    test('is null until a server has been reached', () {
      expect(clock.offsetMs, isNull);
    });

    test('is measured from the server time at the midpoint of the exchange', () async {
      record();
      // Device believes it is 12:00:10; the server says 12:00:00. Ten seconds fast.
      final fake = _FakeClock(DateTime.utc(2026, 9, 2, 12, 0, 10));
      final server = _Server([(_) => _ok(received: 1, serverTime: '2026-09-02T12:00:00Z')]);

      await serviceFor(server, now: fake.now).syncOnce();

      expect(clock.offsetMs, 10000);
      expect(clock.measuredAt, isNotNull);
    });

    test('round-trip time is halved out of the estimate', () async {
      record();
      // The device and server agree, but four seconds elapse in flight. Attributing the server's
      // timestamp to the moment the response arrived would invent a two-second drift.
      final fake = _FakeClock(DateTime.utc(2026, 9, 2, 12, 0, 0));
      final server = _Server([
        (_) {
          fake.advance(const Duration(seconds: 4));
          return _ok(received: 1, serverTime: '2026-09-02T12:00:02Z');
        },
      ]);

      await serviceFor(server, now: fake.now).syncOnce();

      expect(clock.offsetMs, 0, reason: 'the midpoint of the exchange was 12:00:02');
    });
  });

  group('backoff', () {
    test('grows and is capped', () {
      final backoff = Backoff(initial: const Duration(seconds: 1), maximum: const Duration(seconds: 10));
      for (var attempt = 1; attempt < 20; attempt++) {
        expect(backoff.delayFor(attempt), lessThanOrEqualTo(const Duration(seconds: 10)));
      }
      expect(backoff.delayFor(0), Duration.zero);
    });

    test('is jittered, so a field site does not retry in lockstep', () {
      final backoff = Backoff(initial: const Duration(seconds: 30));
      final delays = {for (var i = 0; i < 50; i++) backoff.delayFor(5)};
      expect(delays.length, greaterThan(1));
    });

    test("the server's Retry-After wins over the local schedule", () {
      final backoff = Backoff(initial: const Duration(seconds: 1));
      expect(
        backoff.nextDelay(1, retryAfter: const Duration(minutes: 5)),
        const Duration(minutes: 5),
      );
    });
  });
}
