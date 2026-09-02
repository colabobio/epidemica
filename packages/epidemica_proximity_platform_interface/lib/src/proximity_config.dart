import 'package:meta/meta.dart';

/// What the participant sees in the Android notification shade while sensing runs.
///
/// Android requires a foreground service notification; its wording is participant-facing and in
/// some jurisdictions forms part of the approved consent materials, so it comes from the study
/// bundle rather than being compiled into the module.
@immutable
class ForegroundNotification {
  const ForegroundNotification({
    this.title = 'Recording contacts',
    this.body = 'This study is measuring time spent near other participants.',
    this.channelName = 'Contact recording',
    this.channelDescription =
        'Shown while the study is measuring proximity to other participants.',
  });

  final String title;
  final String body;
  final String channelName;
  final String channelDescription;

  Map<String, Object?> toJson() => {
    'title': title,
    'body': body,
    'channel_name': channelName,
    'channel_description': channelDescription,
  };
}

/// Everything a platform implementation needs in order to start.
@immutable
class ProximityConfig {
  const ProximityConfig({
    required this.pseudonym,
    required this.serviceUuid,
    this.notification = const ForegroundNotification(),
  });

  /// This participant's pseudonym, as a canonical lowercase UUID. Sent on the wire as 16 bytes.
  final String pseudonym;

  /// The BLE service UUID to advertise and scan for.
  ///
  /// Derived from the study, so devices enrolled in different studies never discover each other.
  /// Scoping by service UUID rather than by a field in the payload keeps study membership off the
  /// air entirely.
  final String serviceUuid;

  final ForegroundNotification notification;

  Map<String, Object?> toJson() => {
    'pseudonym': pseudonym,
    'service_uuid': serviceUuid,
    'notification': notification.toJson(),
  };
}
