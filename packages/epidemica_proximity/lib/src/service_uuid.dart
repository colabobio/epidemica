import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Fixed namespace for Epidemica-derived UUIDs. Arbitrary, but frozen: changing it would silently
/// split a running study into two populations that cannot see each other.
const String epidemicaUuidNamespace = '6f6d1c0e-3a2b-4d5e-8f70-1a2b3c4d5e6f';

/// The BLE service UUID a study advertises and scans for.
///
/// Derived from the study identifier rather than assigned, so no registry is needed and two
/// studies cannot collide by accident. Scoping detection this way keeps study membership off the
/// air entirely: a passive listener sees an unfamiliar service UUID, not a labelled cohort.
///
/// RFC 4122 version 5 (SHA-1, name-based), so the same study identifier always yields the same
/// UUID on every device and every platform.
String studyServiceUuid(String studyId) {
  final digest = sha1.convert([
    ...uuidToBytes(epidemicaUuidNamespace),
    ...utf8.encode(studyId),
  ]);
  final bytes = Uint8List.fromList(digest.bytes.sublist(0, 16));
  bytes[6] = (bytes[6] & 0x0f) | 0x50; // version 5
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
  return uuidFromBytes(bytes);
}

/// The 16 bytes behind a canonical UUID string.
Uint8List uuidToBytes(String uuid) {
  final hex = uuid.replaceAll('-', '');
  if (hex.length != 32) {
    throw FormatException('not a UUID: $uuid');
  }
  final bytes = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}

/// Canonical lowercase 8-4-4-4-12 form.
String uuidFromBytes(Uint8List bytes) {
  if (bytes.length != 16) {
    throw ArgumentError.value(bytes.length, 'bytes.length', 'a UUID is 16 bytes');
  }
  final hex = [
    for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0'),
  ].join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}
