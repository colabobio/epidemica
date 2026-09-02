import 'package:meta/meta.dart';

/// What the server says about this participant.
///
/// The mirror image of an observation envelope. [state] is opaque here for the same reason a
/// payload is opaque to the outbox: `epidemica_core` has no business knowing what a particular
/// study's state means, and the moment it does, one study's vocabulary is in the platform.
@immutable
class ParticipantState {
  const ParticipantState({
    required this.stateVersion,
    required this.studyId,
    required this.subject,
    required this.stateUri,
    required this.revision,
    required this.asOf,
    required this.state,
  });

  /// Versions this build understands. Anything else is refused rather than partly interpreted.
  static const Set<String> supportedVersions = {'1.0'};

  final String stateVersion;
  final String studyId;
  final String subject;

  /// Contract governing [state], exactly as `schema_uri` governs an observation payload.
  final String stateUri;

  /// Increases on every server-side change. Lets a stale response be discarded without comparing
  /// clocks, which matters because the device's clock is the thing least to be trusted.
  final int revision;

  /// When the computation ran — not when it was served, and not when it was fetched.
  final DateTime asOf;

  final Map<String, Object?> state;

  /// How old the computation is. A study that recomputes daily is a day stale by design, and an
  /// interface that cannot say so implies a liveness it does not have.
  Duration ageAt(DateTime now) => now.toUtc().difference(asOf);

  Map<String, Object?> toJson() => {
    'state_version': stateVersion,
    'study_id': studyId,
    'subject': subject,
    'state_uri': stateUri,
    'revision': revision,
    'as_of': asOf.toIso8601String(),
    'state': state,
  };

  /// Parses strictly. A missing or mistyped field throws rather than defaulting, because every
  /// default available here would be a lie about a participant's situation.
  static ParticipantState fromJson(Map<String, Object?> json) {
    final version = json['state_version'];
    if (version is! String || !supportedVersions.contains(version)) {
      throw FormatException('unsupported state_version: $version');
    }
    return ParticipantState(
      stateVersion: version,
      studyId: json['study_id']! as String,
      subject: json['subject']! as String,
      stateUri: json['state_uri']! as String,
      revision: (json['revision']! as num).toInt(),
      asOf: DateTime.parse(json['as_of']! as String).toUtc(),
      state: (json['state']! as Map).cast<String, Object?>(),
    );
  }

  @override
  String toString() =>
      'ParticipantState(rev $revision, as of ${asOf.toIso8601String()}, $stateUri)';
}
