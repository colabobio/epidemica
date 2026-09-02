import 'db/database.dart';

/// Tracks how far this device's clock has drifted from the server's.
///
/// The reference is the study server, not an NTP pool. That is deliberate: the skew that matters
/// for reconciling one participant's observations against another's is the difference each device
/// has from the clock that orders them all, and the ingest response already carries it. An NTP
/// dependency would add a package, a network call and a second failure mode to learn less.
class DeviceClock {
  DeviceClock(this._db);

  static const String _offsetKey = 'clock_offset_ms';
  static const String _measuredAtKey = 'clock_offset_measured_at';

  final EpidemicaDatabase _db;

  /// Device clock minus server clock, in milliseconds.
  ///
  /// Null until a server has actually been reached — never zero as a stand-in. Zero is a
  /// measurement meaning the two agreed, and analysis cannot recover the difference later.
  int? get offsetMs {
    final raw = _db.readMeta(_offsetKey);
    return raw == null ? null : int.tryParse(raw);
  }

  DateTime? get measuredAt {
    final raw = _db.readMeta(_measuredAtKey);
    return raw == null ? null : DateTime.tryParse(raw)?.toUtc();
  }

  /// Records an offset from one request/response pair.
  ///
  /// The server's timestamp is taken to describe the midpoint of the exchange rather than the
  /// moment the response arrived, which removes most of the round trip from the estimate. On a
  /// field site's connection that round trip can be seconds.
  void observe({
    required DateTime serverTime,
    required DateTime sentAt,
    required DateTime receivedAt,
  }) {
    final midpoint = sentAt.add(receivedAt.difference(sentAt) ~/ 2);
    final offset = midpoint.toUtc().difference(serverTime.toUtc()).inMilliseconds;
    _db.transaction(() {
      _db.writeMeta(_offsetKey, '$offset');
      _db.writeMeta(_measuredAtKey, receivedAt.toUtc().toIso8601String());
    });
  }
}
