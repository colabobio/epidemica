import 'package:meta/meta.dart';

/// What the server did with one observation it did not plainly accept.
enum ObservationStatus {
  /// Already held under the same `(device_id, seq)`. The expected result of a safe retry, and
  /// from the client's side indistinguishable from success: the server has it.
  duplicate,

  /// Stored with `validated = false`. Also delivered — retrying would only re-quarantine it — but
  /// worth surfacing, because it means either the server is behind this client or this client is
  /// emitting something its own contract forbids.
  quarantined,

  /// Not stored. The identifying fields could not be read, so no retry can fix it.
  rejected,
}

/// Why an observation was not accepted.
enum RejectionReason {
  /// The server is behind the client and will re-validate after an upgrade. Recoverable.
  unknownEnvelopeVersion,
  unknownPayloadSchema,

  /// A producer is emitting something that violates a contract the server does know. A defect.
  envelopeInvalid,
  payloadInvalid,

  /// Core identifying fields were missing, so nothing could be stored.
  unparseable;

  static RejectionReason? parse(Object? raw) => switch (raw) {
    'unknown_envelope_version' => RejectionReason.unknownEnvelopeVersion,
    'unknown_payload_schema' => RejectionReason.unknownPayloadSchema,
    'envelope_invalid' => RejectionReason.envelopeInvalid,
    'payload_invalid' => RejectionReason.payloadInvalid,
    'unparseable' => RejectionReason.unparseable,
    _ => null,
  };

  /// True when the server, not this client, is the thing that needs to change.
  bool get isServerBehind =>
      this == RejectionReason.unknownEnvelopeVersion ||
      this == RejectionReason.unknownPayloadSchema;
}

@immutable
class ObservationOutcome {
  const ObservationOutcome({
    required this.status,
    this.seq,
    this.index,
    this.reason,
    this.detail,
  });

  /// Null when `seq` itself was unreadable, in which case [index] locates the item.
  final int? seq;

  /// Zero-based position in the submitted array.
  final int? index;

  final ObservationStatus status;
  final RejectionReason? reason;
  final String? detail;

  static ObservationOutcome fromJson(Map<String, Object?> json) => ObservationOutcome(
    seq: (json['seq'] as num?)?.toInt(),
    index: (json['index'] as num?)?.toInt(),
    status: switch (json['status']) {
      'duplicate' => ObservationStatus.duplicate,
      'quarantined' => ObservationStatus.quarantined,
      _ => ObservationStatus.rejected,
    },
    reason: RejectionReason.parse(json['reason']),
    detail: json['detail'] as String?,
  );

  @override
  String toString() => 'ObservationOutcome(seq: $seq, ${status.name}, ${reason?.name})';
}

/// Outcome of one batch upload.
@immutable
class IngestResult {
  const IngestResult({
    required this.received,
    required this.accepted,
    required this.duplicate,
    required this.quarantined,
    required this.rejected,
    required this.exceptions,
    required this.serverTime,
    this.highestSeqAccepted,
  });

  final int received;
  final int accepted;
  final int duplicate;
  final int quarantined;
  final int rejected;
  final int? highestSeqAccepted;

  /// **Only** observations that were not plainly accepted; empty on a clean batch.
  ///
  /// The asymmetry matters. A client that removed from its outbox exactly what appears here would
  /// delete the failures and keep every success, resending them forever.
  final List<ObservationOutcome> exceptions;

  /// The server's clock at the moment it handled the batch — the reference this device measures
  /// its own drift against.
  final DateTime serverTime;

  static IngestResult fromJson(Map<String, Object?> json) => IngestResult(
    received: (json['received']! as num).toInt(),
    accepted: (json['accepted']! as num).toInt(),
    duplicate: (json['duplicate']! as num).toInt(),
    quarantined: (json['quarantined']! as num).toInt(),
    rejected: (json['rejected']! as num).toInt(),
    highestSeqAccepted: (json['highest_seq_accepted'] as num?)?.toInt(),
    exceptions: [
      for (final e in (json['exceptions'] as List? ?? const []))
        ObservationOutcome.fromJson((e! as Map).cast<String, Object?>()),
    ],
    serverTime: DateTime.parse(json['server_time']! as String).toUtc(),
  );
}

/// What the server already holds for this device and study.
@immutable
class IngestWatermark {
  const IngestWatermark({required this.highestContiguousSeq, required this.serverTime});

  final int highestContiguousSeq;
  final DateTime serverTime;

  static IngestWatermark fromJson(Map<String, Object?> json) => IngestWatermark(
    highestContiguousSeq: (json['highest_contiguous_seq'] as num?)?.toInt() ?? 0,
    serverTime: DateTime.parse(json['server_time']! as String).toUtc(),
  );
}
