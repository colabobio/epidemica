import 'package:meta/meta.dart';

import '../enrollment.dart';
import '../clock.dart';
import '../outbox.dart';

/// A module this binary embeds.
///
/// The module set is fixed at build time (ADR-0001), so implementations of this interface are what
/// a binary *can* do. Which of them run, and how, is decided by the study bundle.
///
/// Lives in core rather than in an app because every app that hosts modules needs the same
/// interface, and because module health reporting has to be generic. Core defines the interface;
/// nothing in core depends on any module.
abstract class EmbeddedModule {
  /// Matches the key in a bundle's `modules` map and the envelope's `module` field.
  String get id;

  Future<void> start(ModuleContext context);

  Future<void> stop();

  /// Whether this module is currently collecting, and if not, why not.
  ///
  /// Asked periodically rather than reported spontaneously, so a module that has stopped
  /// unexpectedly still answers.
  Future<ModuleStatus> status();
}

/// Everything a module needs from the app, and nothing more.
///
/// A module never sees the whole bundle, the outbox, or another module's configuration. Narrow on
/// purpose: a module that can read the whole bundle grows opinions about other modules'
/// configuration, and the coupling stays invisible until two studies disagree.
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
  final ObservationRecorder record;
}

/// Appends an observation attributed to one module.
typedef ObservationRecorder =
    int Function({
      required String schemaUri,
      required DateTime observedAt,
      required Map<String, Object?> payload,
    });

/// What a module is doing.
enum ModuleState {
  /// The only state that asserts observation.
  sensing,

  stopped,
  permissionDenied,
  radioOff;

  String toJson() => switch (this) {
    ModuleState.sensing => 'sensing',
    ModuleState.stopped => 'stopped',
    ModuleState.permissionDenied => 'permission_denied',
    ModuleState.radioOff => 'radio_off',
  };
}

@immutable
class ModuleStatus {
  const ModuleStatus(this.state, {this.detail});

  final ModuleState state;

  /// Which permission, or which radio. Never participant data.
  final String? detail;

  bool get isSensing => state == ModuleState.sensing;
}

/// Builds the recorder a module is given, binding the envelope fields a module has no business
/// choosing for itself.
ObservationRecorder recorderFor({
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
