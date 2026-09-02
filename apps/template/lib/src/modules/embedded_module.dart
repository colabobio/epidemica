import 'package:epidemica_core/epidemica_core.dart';

/// A module this binary embeds.
///
/// The module set is fixed at build time (ADR-0001), so implementations of this interface are what
/// a binary *can* do. Which of them actually run, and how, is decided by the study bundle.
abstract class EmbeddedModule {
  /// Matches the key used in a bundle's `modules` map and in an observation's `module` field.
  String get id;

  /// Begin collecting, configured by [context].
  Future<void> start(ModuleContext context);

  Future<void> stop();
}

/// Everything a module needs from the app, and nothing more.
///
/// A module never sees the whole bundle, the outbox, or another module's configuration. It is
/// handed its own settings and one way to emit an observation, which is what keeps a module from
/// growing opinions about how data reaches a server.
class ModuleContext {
  ModuleContext({
    required this.config,
    required this.studyId,
    required this.subject,
    required this.record,
  });

  /// This module's block from the bundle.
  final Map<String, Object?> config;

  final String studyId;

  /// This participant's pseudonym.
  final String subject;

  /// Appends an observation to the outbox. Returns its sequence number.
  final int Function({
    required String schemaUri,
    required DateTime observedAt,
    required Map<String, Object?> payload,
  })
  record;
}

/// Builds the observation recorder a module is given, binding the envelope fields the module has
/// no business choosing for itself.
int Function({
  required String schemaUri,
  required DateTime observedAt,
  required Map<String, Object?> payload,
})
recorderFor({
  required Outbox outbox,
  required Enrollment enrollment,
  required DeviceClock clock,
  required String module,
}) {
  return ({
    required String schemaUri,
    required DateTime observedAt,
    required Map<String, Object?> payload,
  }) => outbox.record(
    studyId: enrollment.studyId,
    protocolHash: enrollment.protocolHash,
    subject: enrollment.subject,
    deviceId: enrollment.deviceId,
    module: module,
    schemaUri: schemaUri,
    observedAt: observedAt,
    // Null until a server has been reached, which is a different statement from "no drift".
    clockOffsetMs: clock.offsetMs,
    payload: payload,
  );
}
