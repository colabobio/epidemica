import 'dart:math';

import 'package:meta/meta.dart';

import '../clock.dart';
import '../outbox.dart';
import 'backoff.dart';
import 'ingest_client.dart';
import 'ingest_result.dart';

/// What one sync pass did.
@immutable
class SyncReport {
  const SyncReport({
    this.delivered = 0,
    this.duplicates = 0,
    this.quarantined = 0,
    this.deadLettered = 0,
    this.batches = 0,
    this.remaining = 0,
    this.retryAfter,
    this.error,
  });

  /// Observations the server now holds, including duplicates and quarantines.
  final int delivered;
  final int duplicates;
  final int quarantined;
  final int deadLettered;
  final int batches;

  /// Still queued when the pass ended.
  final int remaining;

  /// How long to wait before trying again, when the server or the backoff said so.
  final Duration? retryAfter;

  final Object? error;

  bool get isComplete => remaining == 0 && error == null;

  SyncReport _plus({
    int delivered = 0,
    int duplicates = 0,
    int quarantined = 0,
    int deadLettered = 0,
    int batches = 0,
    int? remaining,
    Duration? retryAfter,
    Object? error,
  }) => SyncReport(
    delivered: this.delivered + delivered,
    duplicates: this.duplicates + duplicates,
    quarantined: this.quarantined + quarantined,
    deadLettered: this.deadLettered + deadLettered,
    batches: this.batches + batches,
    remaining: remaining ?? this.remaining,
    retryAfter: retryAfter ?? this.retryAfter,
    error: error ?? this.error,
  );

  @override
  String toString() =>
      'SyncReport(delivered: $delivered, duplicates: $duplicates, '
      'quarantined: $quarantined, deadLettered: $deadLettered, remaining: $remaining)';
}

/// Drains the outbox to the server.
///
/// One pass, no timers: when to call this is a policy decision that belongs to whatever is
/// managing the background service, not here.
class SyncService {
  SyncService({
    required Outbox outbox,
    required IngestClient client,
    required DeviceClock clock,
    Backoff? backoff,
    int batchSize = Outbox.maxBatchSize,
    DateTime Function()? now,
  }) : _outbox = outbox,
       _client = client,
       _clock = clock,
       _backoff = backoff ?? Backoff(),
       _batchSize = batchSize,
       _now = now ?? DateTime.now;

  final Outbox _outbox;
  final IngestClient _client;
  final DeviceClock _clock;
  final Backoff _backoff;
  final DateTime Function() _now;

  int _batchSize;
  int _consecutiveFailures = 0;

  /// Uploads until the outbox is empty or something says to stop.
  Future<SyncReport> syncOnce({int maxBatches = 1000}) async {
    _outbox.reclaimStale(now: _now());
    var report = const SyncReport();

    for (var i = 0; i < maxBatches; i++) {
      final claimToken = _claimToken();
      final claimed = _outbox.claimBatch(
        claimToken: claimToken,
        limit: _batchSize,
        now: _now(),
      );
      if (claimed.isEmpty) break;

      try {
        report = report._plus(batches: 1) + await _uploadClaim(claimed);
        _consecutiveFailures = 0;
      } on IngestPayloadTooLarge {
        _outbox.releaseClaim(claimToken);
        if (_batchSize <= 1) {
          return report._plus(
            remaining: _outbox.pendingCount(),
            error: const IngestPayloadTooLarge(),
          );
        }
        // A single observation the server will not accept at any size is a contract problem, but
        // a batch that is merely too big is arithmetic. Halve and carry on.
        _batchSize = max(1, _batchSize ~/ 2);
        continue;
      } on IngestRateLimited catch (e) {
        _outbox.releaseClaim(claimToken);
        _consecutiveFailures++;
        return report._plus(
          remaining: _outbox.pendingCount(),
          retryAfter: _backoff.nextDelay(_consecutiveFailures, retryAfter: e.retryAfter),
        );
      } on IngestTransient catch (e) {
        _outbox.releaseClaim(claimToken);
        _consecutiveFailures++;
        return report._plus(
          remaining: _outbox.pendingCount(),
          retryAfter: _backoff.nextDelay(_consecutiveFailures),
          error: e,
        );
      } on IngestException catch (e) {
        // Unauthorized or refused: the request will fail identically next time, so stop rather
        // than spending a field site's battery discovering that repeatedly.
        _outbox.releaseClaim(claimToken);
        return report._plus(remaining: _outbox.pendingCount(), error: e);
      }
    }

    return report._plus(remaining: _outbox.pendingCount());
  }

  Future<SyncReport> _uploadClaim(List<OutboxEntry> claimed) async {
    final sentAt = _now();
    final result = await _client.upload([for (final e in claimed) e.toEnvelope()]);
    final receivedAt = _now();

    _clock.observe(serverTime: result.serverTime, sentAt: sentAt, receivedAt: receivedAt);

    return _applyOutcomes(claimed, result);
  }

  SyncReport _applyOutcomes(List<OutboxEntry> claimed, IngestResult result) {
    final rejected = <int>{};
    var duplicates = 0;
    var quarantined = 0;

    for (final outcome in result.exceptions) {
      // `seq` is null when the server could not read it, in which case `index` locates the item.
      final seq = outcome.seq ??
          (outcome.index != null && outcome.index! < claimed.length
              ? claimed[outcome.index!].seq
              : null);
      if (seq == null) continue;

      switch (outcome.status) {
        case ObservationStatus.rejected:
          _outbox.deadLetter(
            seq,
            reason: outcome.reason?.name ?? 'rejected',
            detail: outcome.detail,
            now: _now(),
          );
          rejected.add(seq);
        case ObservationStatus.duplicate:
          duplicates++;
        case ObservationStatus.quarantined:
          // Stored server-side with validated = false. Delivered, so it leaves the outbox;
          // retrying would only re-quarantine it.
          quarantined++;
      }
    }

    // Everything except the rejections is now the server's. The contract omits accepted
    // observations from `exceptions`, so a client that removed only what the server listed would
    // delete its failures, keep every success, and resend them forever.
    final delivered = [
      for (final entry in claimed)
        if (!rejected.contains(entry.seq)) entry.seq,
    ];
    _outbox.markDelivered(delivered);

    return SyncReport(
      delivered: delivered.length,
      duplicates: duplicates,
      quarantined: quarantined,
      deadLettered: rejected.length,
    );
  }

  String _claimToken() =>
      '${_now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';
}

extension on SyncReport {
  SyncReport operator +(SyncReport other) => _plus(
    delivered: other.delivered,
    duplicates: other.duplicates,
    quarantined: other.quarantined,
    deadLettered: other.deadLettered,
  );
}
