import 'dart:math';

import 'db/database.dart';

/// This installation's stable identifiers.
///
/// Both live in the local database rather than secure storage, for two reasons. They are not
/// secrets — the pseudonym is broadcast over Bluetooth — and, more practically, the background
/// isolate needs them to build envelopes. Secure storage is a plugin, and plugin access from a
/// service isolate is exactly the thing that fails intermittently on Android.
class Identity {
  Identity(this._db);

  static const String _subjectKey = 'subject';
  static const String _deviceIdKey = 'device_id';

  final EpidemicaDatabase _db;

  /// The participant pseudonym, generated here and never derived from anything about the person.
  ///
  /// Generating it on the device is what allows a study to hold no participant identifier at all.
  /// It is a v4 UUID, which satisfies the envelope's `^[A-Za-z0-9_-]+$` guard — a character class
  /// chosen so an email address cannot be submitted here by accident.
  String get subject => _stable(_subjectKey);

  /// Identifies one app installation, not one person and not one physical device. Reinstalling
  /// produces a new one, which is why `seq` is scoped to it.
  String get deviceId => _stable(_deviceIdKey);

  bool get isEstablished =>
      _db.readMeta(_subjectKey) != null && _db.readMeta(_deviceIdKey) != null;

  String _stable(String key) {
    final existing = _db.readMeta(key);
    if (existing != null) return existing;

    return _db.transaction(() {
      // Re-read inside the transaction: another isolate may have won the race to create it.
      final concurrent = _db.readMeta(key);
      if (concurrent != null) return concurrent;
      final value = newUuidV4();
      _db.writeMeta(key, value);
      return value;
    });
  }

  /// A random v4 UUID from a cryptographic source.
  ///
  /// `Random()` would be seeded predictably enough to make one participant's pseudonym guessable
  /// from another's, and in a study that holds no other identifier the pseudonym *is* the privacy
  /// model.
  static String newUuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
