import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

/// Permissions the proximity module needs, in the form the platform actually asks for them.
///
/// The plugin's manifest already *declares* what it needs; only the participant can grant it. What
/// is requested differs by platform version: Android 12 removed the need to ask for location just
/// to scan for Bluetooth devices, and a research app should not ask for it on a device where it is
/// not required.
class Permissions {
  const Permissions._();

  /// Returns the permissions still denied after asking.
  static Future<List<String>> requestForProximity() async {
    final wanted = <Permission>[];

    if (Platform.isAndroid) {
      wanted.addAll([
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
        // Without this the foreground-service notification is hidden, and a participant cannot
        // see that the study is running — which most ethics boards will not accept.
        Permission.notification,
      ]);
    } else {
      wanted.add(Permission.bluetooth);
    }

    final results = await wanted.request();
    return [
      for (final entry in results.entries)
        if (!entry.value.isGranted) _describe(entry.key),
    ];
  }

  static String _describe(Permission permission) => switch (permission) {
    Permission.bluetoothScan => 'find nearby devices',
    Permission.bluetoothAdvertise => 'be visible to nearby devices',
    Permission.bluetoothConnect => 'use Bluetooth',
    Permission.notification => 'show that the study is running',
    _ => 'use Bluetooth',
  };
}
