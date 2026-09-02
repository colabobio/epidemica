import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:sqlite3/sqlite3.dart';

import 'db/database.dart';

/// One observation waiting to be delivered, in envelope form.
@immutable
class OutboxEntry {
  const OutboxEntry({
    required this.seq,
    required this.studyId,
    required this.protocolHash,
    required this.subject,
    required this.deviceId,
    required this.module,
    required this.schemaUri,
    required this.observedAt,
    required this.clockOffsetMs,
    required this.payload,
    this.envelopeVersion = '1.0',
  });

  final int seq;
  final String studyId;
  final String protocolHash;
  final String subject;
  final String deviceId;
  final String module;
  final String schemaUri;
  final DateTime observedAt;

  /// Null, not zero, when no reference clock has ever been reached. Zero is a measurement — it
  /// says the device agreed with the server — and analysis cannot tell one from the other after
  /// the fact.
  final int? clockOffsetMs;

  final Map<String, Object?> payload;
  final String envelopeVersion;

  Map<String, Object?> toEnvelope() => {
    'envelope_version': envelopeVersion,
    'study_id': studyId,
    'protocol_hash': protocolHash,
    'subject': subject,
    'device_id': deviceId,
    'module': module,
    'schema_uri': schemaUri,
    'observed_at': _iso(observedAt),
    'clock_offset_ms': clockOffsetMs,
    'seq': seq,
    'payload': payload,
  };

  static OutboxEntry _fromRow(Row row) => OutboxEntry(
    seq: row['seq'] as int,
    studyId: row['study_id'] as String,
    protocolHash: row['protocol_hash'] as String,
    subject: row['subject'] as String,
    deviceId: row['device_id'] as String,
    module: row['module'] as String,
    schemaUri: row['schema_uri'] as String,
    observedAt: DateTime.parse(row['observed_at'] as String).toUtc(),
    clockOffsetMs: row['clock_offset_ms'] as int?,
    payload: (jsonDecode(row['payload'] as String) as Map).cast<String, Object?>(),
  );

  /// UTC with a `Z`, and no `.000` on a whole second, matching the envelope contract.
  static String _iso(DateTime dt) {
    final s = dt.toUtc().toIso8601String();
    return s.endsWith('.000Z') ? '${s.substring(0, s.length - 5)}Z' : s;
  }
}

/// An observation the server refused, kept for inspection.
@immutable
class DeadLetter {
  const DeadLetter({
    required this.seq,
    required this.module,
    required this.schemaUri,
    required this.reason,
    required this.detail,
    required this.rejectedAt,
    required this.payload,
  });

  final int seq;
  final String module;
  final String schemaUri;
  final String reason;
  final String? detail;
  final DateTime rejectedAt;
  final Map<String, Object?> payload;
}

/// The durable queue between a module and the server.
///
/// Modules call [record] and are done; nothing else in the app needs to know whether the network
/// exists. Everything here is designed around one requirement: an observation that has been
/// recorded is delivered exactly once, or is visibly parked, but is never quietly lost.
class Outbox {
  Outbox(this._db);

  final EpidemicaDatabase _db;

  /// A claim older than this is presumed abandoned — the process died mid-upload — and the rows
  /// are returned to the queue. Long enough that a slow upload on a bad connection is not
  /// reclaimed underneath itself.
  static const Duration claimTimeout = Duration(minutes: 5);

  /// Appends an observation and returns its sequence number.
  ///
  /// The `seq` is allocated by the same INSERT that writes the row, so two isolates recording at
  /// once cannot be handed the same number and cannot leave a hole. Allocating it beforehand —
  /// reading a counter, then inserting — is the obvious implementation and is wrong.
  int record({
    required String studyId,
    required String protocolHash,
    required String subject,
    required String deviceId,
    required String module,
    required String schemaUri,
    required DateTime observedAt,
    required Map<String, Object?> payload,
    int? clockOffsetMs,
    DateTime? now,
  }) {
    return _db.transaction(() {
      _db.db.execute(
        'INSERT INTO outbox (study_id, protocol_hash, subject, device_id, module, schema_uri, '
        'observed_at, clock_offset_ms, payload, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          studyId,
          protocolHash,
          subject,
          deviceId,
          module,
          schemaUri,
          OutboxEntry._iso(observedAt),
          clockOffsetMs,
          jsonEncode(payload),
          OutboxEntry._iso(now ?? DateTime.now()),
        ],
      );
      return _db.db.lastInsertRowId;
    });
  }

  int pendingCount() =>
      _db.db.select('SELECT COUNT(*) AS n FROM outbox').first['n'] as int;

  int unclaimedCount() => _db.db
      .select('SELECT COUNT(*) AS n FROM outbox WHERE claimed_at IS NULL')
      .first['n'] as int;

  /// Takes up to [limit] pending rows for delivery, marking them so a concurrent sync in another
  /// isolate cannot pick up the same work.
  ///
  /// Claim-then-upload rather than upload-then-delete: if the process dies between the two, the
  /// rows reappear after [claimTimeout] and are retried. The server deduplicates on
  /// `(device_id, seq)`, so a retry that was in fact delivered comes back as `duplicate` rather
  /// than creating a second row.
  List<OutboxEntry> claimBatch({
    required String claimToken,
    int limit = maxBatchSize,
    DateTime? now,
  }) {
    final at = OutboxEntry._iso(now ?? DateTime.now());
    return _db.transaction(() {
      final rows = _db.db.select(
        'SELECT * FROM outbox WHERE claimed_at IS NULL ORDER BY seq LIMIT ?',
        [limit],
      );
      if (rows.isEmpty) return const <OutboxEntry>[];

      final seqs = rows.map((r) => r['seq'] as int).toList();
      _db.db.execute(
        'UPDATE outbox SET claimed_at = ?, claim_token = ? '
        'WHERE seq IN (${List.filled(seqs.length, '?').join(',')})',
        [at, claimToken, ...seqs],
      );
      return rows.map(OutboxEntry._fromRow).toList();
    });
  }

  /// The batch size the ingest contract allows.
  static const int maxBatchSize = 1000;

  /// Removes rows the server has taken responsibility for.
  ///
  /// `duplicate` counts as delivered: it means the server already holds that `(device_id, seq)`,
  /// which is precisely the outcome a retried claim should produce.
  void markDelivered(Iterable<int> seqs) {
    final list = seqs.toList();
    if (list.isEmpty) return;
    _db.transaction(() {
      _db.db.execute(
        'DELETE FROM outbox WHERE seq IN (${List.filled(list.length, '?').join(',')})',
        list,
      );
    });
  }

  /// Returns a claim to the queue and counts the attempt.
  void releaseClaim(String claimToken) {
    _db.transaction(() {
      _db.db.execute(
        'UPDATE outbox SET claimed_at = NULL, claim_token = NULL, attempts = attempts + 1 '
        'WHERE claim_token = ?',
        [claimToken],
      );
    });
  }

  /// Frees claims abandoned by a process that died mid-upload.
  int reclaimStale({Duration timeout = claimTimeout, DateTime? now}) {
    final cutoff = OutboxEntry._iso((now ?? DateTime.now()).subtract(timeout));
    return _db.transaction(() {
      _db.db.execute(
        'UPDATE outbox SET claimed_at = NULL, claim_token = NULL, attempts = attempts + 1 '
        'WHERE claimed_at IS NOT NULL AND claimed_at < ?',
        [cutoff],
      );
      return _db.db.updatedRows;
    });
  }

  /// Moves a rejected observation out of the queue and into the dead-letter store.
  ///
  /// Rejection means this build produced something the contract forbids. Retrying cannot fix it,
  /// and deleting it would leave the study with a hole and no explanation, so it is parked where
  /// it can be found.
  void deadLetter(int seq, {required String reason, String? detail, DateTime? now}) {
    _db.transaction(() {
      _db.db.execute(
        'INSERT OR REPLACE INTO dead_letter '
        '(seq, study_id, protocol_hash, subject, device_id, module, schema_uri, observed_at, '
        ' clock_offset_ms, payload, created_at, reason, detail, rejected_at) '
        'SELECT seq, study_id, protocol_hash, subject, device_id, module, schema_uri, '
        '       observed_at, clock_offset_ms, payload, created_at, ?, ?, ? '
        'FROM outbox WHERE seq = ?',
        [reason, detail, OutboxEntry._iso(now ?? DateTime.now()), seq],
      );
      _db.db.execute('DELETE FROM outbox WHERE seq = ?', [seq]);
    });
  }

  List<DeadLetter> deadLetters({bool onlyUnsurfaced = false}) {
    final rows = _db.db.select(
      'SELECT * FROM dead_letter${onlyUnsurfaced ? ' WHERE surfaced = 0' : ''} ORDER BY seq',
    );
    return [
      for (final row in rows)
        DeadLetter(
          seq: row['seq'] as int,
          module: row['module'] as String,
          schemaUri: row['schema_uri'] as String,
          reason: row['reason'] as String,
          detail: row['detail'] as String?,
          rejectedAt: DateTime.parse(row['rejected_at'] as String).toUtc(),
          payload: (jsonDecode(row['payload'] as String) as Map).cast<String, Object?>(),
        ),
    ];
  }

  /// Records that a dead letter has been reported to someone who can act on it.
  void markSurfaced(Iterable<int> seqs) {
    final list = seqs.toList();
    if (list.isEmpty) return;
    _db.transaction(() {
      _db.db.execute(
        'UPDATE dead_letter SET surfaced = 1 '
        'WHERE seq IN (${List.filled(list.length, '?').join(',')})',
        list,
      );
    });
  }

  /// Highest sequence number ever allocated, whether or not the row still exists.
  ///
  /// Read from SQLite's own counter rather than from `MAX(seq)`, which would fall back to zero
  /// once the queue drains and start the numbering again.
  int highestAllocatedSeq() {
    final rows = _db.db.select(
      "SELECT seq FROM sqlite_sequence WHERE name = 'outbox'",
    );
    return rows.isEmpty ? 0 : rows.first['seq'] as int;
  }
}
