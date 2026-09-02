import 'dart:io';
import 'dart:isolate';

import 'package:epidemica_core/src/db/database.dart';
import 'package:epidemica_core/src/outbox.dart';
import 'package:flutter_test/flutter_test.dart';

/// Inserts rows into the outbox at [path] from a separate isolate.
///
/// Top-level so it can be sent to `Isolate.run`, which is the point: this is the background
/// service writing while the main isolate holds its own connection open.
int _recordFromIsolate((String path, String module, int count) args) {
  final (path, module, count) = args;
  final db = EpidemicaDatabase.open(path);
  final outbox = Outbox(db);
  for (var i = 0; i < count; i++) {
    outbox.record(
      studyId: 'study-1',
      protocolHash: 'sha256:${'a' * 64}',
      subject: 'subject-0001',
      deviceId: 'device-1',
      module: module,
      schemaUri: 'https://schemas.epidemica.info/x/1.0.0.json',
      observedAt: DateTime.utc(2026, 9, 2, 12, i % 60),
      payload: {'i': i},
    );
  }
  db.close();
  return count;
}

/// Top-level so the closure handed to [Isolate.run] captures only these three values. A closure
/// written inside a test body captures the whole enclosing context, including the test's open
/// database handle, which is not sendable.
Future<int> _spawnRecorder(String path, String module, int count) =>
    Isolate.run(() => _recordFromIsolate((path, module, count)));

void main() {
  late Directory dir;
  late EpidemicaDatabase db;
  late Outbox outbox;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('epidemica_outbox');
    db = EpidemicaDatabase.open('${dir.path}/epidemica.db');
    outbox = Outbox(db);
  });

  tearDown(() {
    db.close();
    dir.deleteSync(recursive: true);
  });

  int record({String module = 'proximity', DateTime? observedAt, int? clockOffsetMs}) =>
      outbox.record(
        studyId: 'study-1',
        protocolHash: 'sha256:${'a' * 64}',
        subject: 'subject-0001',
        deviceId: 'device-1',
        module: module,
        schemaUri: 'https://schemas.epidemica.info/x/1.0.0.json',
        observedAt: observedAt ?? DateTime.utc(2026, 9, 2, 12),
        clockOffsetMs: clockOffsetMs,
        payload: {'hello': 'world'},
      );

  group('recording', () {
    test('allocates sequence numbers from one', () {
      expect(record(), 1);
      expect(record(), 2);
      expect(outbox.pendingCount(), 2);
    });

    test('produces an envelope with every required field', () {
      record(clockOffsetMs: -1200);
      final envelope = outbox
          .claimBatch(claimToken: 'c1')
          .single
          .toEnvelope();

      expect(envelope.keys, containsAll([
        'envelope_version', 'study_id', 'protocol_hash', 'subject', 'device_id',
        'module', 'schema_uri', 'observed_at', 'clock_offset_ms', 'seq', 'payload',
      ]));
      expect(envelope['observed_at'], '2026-09-02T12:00:00Z');
      expect(envelope['clock_offset_ms'], -1200);
      expect(envelope['seq'], 1);
    });

    test('an unknown clock offset is null, not zero', () {
      record();
      final envelope = outbox.claimBatch(claimToken: 'c1').single.toEnvelope();

      // Zero is a measurement: it says the device agreed with the server. Analysis cannot tell
      // that apart from "never checked" after the fact.
      expect(envelope['clock_offset_ms'], isNull);
    });
  });

  group('sequence numbers', () {
    test('are not reused after the queue drains', () {
      record();
      record();
      outbox.markDelivered([1, 2]);
      expect(outbox.pendingCount(), 0);

      // A plain rowid would restart at 1 here, reissuing numbers the server already holds under
      // (device_id, seq). It would deduplicate the new observations away as duplicates.
      expect(record(), 3);
      expect(outbox.highestAllocatedSeq(), 3);
    });

    test('two isolates writing at once produce no duplicates and no gaps', () async {
      final path = '${dir.path}/epidemica.db';

      await Future.wait([
        _spawnRecorder(path, 'proximity', 200),
        _spawnRecorder(path, 'instruments', 200),
      ]);

      final rows = db.db.select('SELECT seq FROM outbox ORDER BY seq');
      final seqs = [for (final row in rows) row['seq'] as int];

      expect(seqs.length, 400);
      expect(seqs.toSet().length, 400, reason: 'duplicate sequence numbers');
      expect(seqs, List.generate(400, (i) => i + 1), reason: 'gaps in the sequence');
    });

    test('the main isolate can write while a background isolate holds a connection', () async {
      final path = '${dir.path}/epidemica.db';
      final background = _spawnRecorder(path, 'proximity', 100);

      for (var i = 0; i < 100; i++) {
        record(module: 'instruments');
      }
      await background;

      expect(outbox.pendingCount(), 200);
    });
  });

  group('claiming', () {
    test('a claimed batch is not handed out twice', () {
      for (var i = 0; i < 5; i++) {
        record();
      }

      final first = outbox.claimBatch(claimToken: 'c1', limit: 3);
      final second = outbox.claimBatch(claimToken: 'c2', limit: 3);

      expect(first.map((e) => e.seq), [1, 2, 3]);
      expect(second.map((e) => e.seq), [4, 5]);
    });

    test('releasing a claim returns the rows and counts the attempt', () {
      record();
      outbox.claimBatch(claimToken: 'c1');
      expect(outbox.unclaimedCount(), 0);

      outbox.releaseClaim('c1');

      expect(outbox.unclaimedCount(), 1);
      expect(db.db.select('SELECT attempts FROM outbox').first['attempts'], 1);
    });

    test('a claim abandoned by a dead process is reclaimed', () {
      record();
      final start = DateTime.utc(2026, 9, 2, 12);
      outbox.claimBatch(claimToken: 'c1', now: start);

      expect(outbox.reclaimStale(now: start.add(const Duration(minutes: 1))), 0);
      expect(outbox.reclaimStale(now: start.add(const Duration(minutes: 10))), 1);
      expect(outbox.unclaimedCount(), 1);
    });

    test('batches are capped at the size the ingest contract allows', () {
      expect(Outbox.maxBatchSize, 1000);
      for (var i = 0; i < 1200; i++) {
        record();
      }
      expect(outbox.claimBatch(claimToken: 'c1').length, 1000);
    });
  });

  group('dead letters', () {
    test('a rejected observation is parked, not deleted', () {
      record(module: 'proximity');
      outbox.deadLetter(1, reason: 'schema_violation', detail: 'band_seconds: negative');

      expect(outbox.pendingCount(), 0);
      final parked = outbox.deadLetters().single;
      expect(parked.seq, 1);
      expect(parked.reason, 'schema_violation');
      expect(parked.detail, 'band_seconds: negative');
      expect(parked.payload, {'hello': 'world'});
    });

    test('parking does not free the sequence number for reuse', () {
      record();
      outbox.deadLetter(1, reason: 'schema_violation');
      expect(record(), 2);
    });

    test('unsurfaced dead letters can be found and then marked', () {
      record();
      record();
      outbox.deadLetter(1, reason: 'schema_violation');
      outbox.deadLetter(2, reason: 'unknown_module');

      expect(outbox.deadLetters(onlyUnsurfaced: true).length, 2);
      outbox.markSurfaced([1]);
      expect(outbox.deadLetters(onlyUnsurfaced: true).map((d) => d.seq), [2]);
      expect(outbox.deadLetters().length, 2, reason: 'surfacing must not delete the evidence');
    });
  });

  group('durability', () {
    test('records survive closing and reopening the database', () {
      final path = '${dir.path}/reopen.db';
      final first = EpidemicaDatabase.open(path);
      Outbox(first).record(
        studyId: 'study-1',
        protocolHash: 'sha256:${'a' * 64}',
        subject: 'subject-0001',
        deviceId: 'device-1',
        module: 'proximity',
        schemaUri: 'https://schemas.epidemica.info/x/1.0.0.json',
        observedAt: DateTime.utc(2026, 9, 2, 12),
        payload: {'hello': 'world'},
      );
      first.close();

      final second = EpidemicaDatabase.open(path);
      expect(Outbox(second).pendingCount(), 1);
      second.close();
    });

    test('the store is in WAL mode', () {
      expect(db.db.select('PRAGMA journal_mode').first.values.first, 'wal');
    });

    test('migration is idempotent across connections', () {
      final path = '${dir.path}/migrate.db';
      final a = EpidemicaDatabase.open(path);
      final b = EpidemicaDatabase.open(path);
      a.migrate();
      b.migrate();
      expect(Outbox(b).pendingCount(), 0);
      a.close();
      b.close();
    });
  });
}
