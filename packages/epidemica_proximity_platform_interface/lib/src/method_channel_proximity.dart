import 'package:flutter/services.dart';

import 'device_class.dart';
import 'proximity_config.dart';
import 'proximity_event.dart';
import 'proximity_platform.dart';

/// The default [ProximityPlatform], talking to native over method and event channels.
///
/// Lives in the interface package because both platform implementations speak exactly the same
/// protocol; duplicating it would let iOS and Android drift apart in Dart as well as in native
/// code, which is the failure this whole federated split exists to prevent.
class MethodChannelProximity extends ProximityPlatform {
  static const MethodChannel methods = MethodChannel('info.epidemica.proximity/methods');
  static const EventChannel eventChannel = EventChannel('info.epidemica.proximity/events');

  Stream<ProximityEvent>? _events;

  @override
  Stream<ProximityEvent> get events =>
      _events ??= eventChannel.receiveBroadcastStream().map(decodeEvent).where((e) => e != null).cast<ProximityEvent>();

  @override
  Future<void> start(ProximityConfig config) async =>
      methods.invokeMethod<void>('start', config.toJson());

  @override
  Future<void> stop() async => methods.invokeMethod<void>('stop');

  @override
  Future<bool> isRunning() async =>
      await methods.invokeMethod<bool>('isRunning') ?? false;

  /// Absent or unanswerable is treated as off. Assuming the radio is on would manufacture coverage
  /// the device cannot actually provide.
  @override
  Future<bool> isRadioEnabled() async =>
      await methods.invokeMethod<bool>('isRadioEnabled') ?? false;

  @override
  Future<DeviceClass> observerDeviceClass() async =>
      DeviceClass.fromJson(await methods.invokeMethod<String>('observerDeviceClass'));

  @override
  Future<List<String>> missingPlatformRequirements() async =>
      (await methods.invokeListMethod<String>('missingPlatformRequirements')) ?? const [];

  /// Unknown event types are dropped rather than thrown on: a newer native side talking to an
  /// older Dart side should degrade to missing diagnostics, not a dead stream.
  static ProximityEvent? decodeEvent(Object? raw) {
    if (raw is! Map) return null;
    final json = raw.cast<Object?, Object?>().map(
      (key, value) => MapEntry(key.toString(), value),
    );
    return switch (json['type']) {
      'detection' => ProximityDetection.fromJson(json),
      'started' => const ProximitySensingStarted(),
      'sync_due' => const SyncDue(),
      'dropped' => ProximityDetectionsDropped(
        count: (json['count']! as num).toInt(),
        oldestRetained: switch (json['oldest_retained_ms']) {
          final num ms => DateTime.fromMillisecondsSinceEpoch(ms.toInt(), isUtc: true),
          _ => null,
        },
      ),
      _ => null,
    };
  }
}
