import 'dart:convert';

import 'package:http/http.dart' as http;

import '../db/database.dart';
import '../sync/ingest_client.dart';
import 'participant_state.dart';

/// Fetches and caches what the server says about this participant.
///
/// The downward half of the platform. Observations go up through the outbox; state comes back
/// through here. Core validates the envelope and caches the document, and never looks inside
/// [ParticipantState.state].
class StateChannel {
  StateChannel({
    required this.baseUri,
    required EpidemicaDatabase db,
    required AccessTokenSource tokens,
    http.Client? httpClient,
  }) : _db = db,
       _tokens = tokens,
       _http = httpClient ?? http.Client();

  static const String _cacheKey = 'participant_state';

  final Uri baseUri;
  final EpidemicaDatabase _db;
  final AccessTokenSource _tokens;
  final http.Client _http;

  ParticipantState? _cached;

  /// The last document received, or null if none ever was.
  ///
  /// Always reflects a real server computation. Nothing here ever manufactures a state document:
  /// an invented "you are healthy" is indistinguishable from a measured one, and a participant
  /// acting on it would be acting on fiction.
  ParticipantState? current({String? expectedSubject}) {
    final cached = _cached ??= _readCache();
    if (cached == null) return null;
    // A document belonging to a previous enrollment on this device is not this participant's.
    if (expectedSubject != null && cached.subject != expectedSubject) return null;
    return cached;
  }

  /// Asks the server for the current state.
  ///
  /// Returns the newest document known afterwards, which may be the cached one when the server has
  /// nothing newer. Throws on transport or authorisation failure, so a caller can distinguish
  /// "nothing has changed" from "we could not ask".
  Future<ParticipantState?> refresh() async {
    final http.Response response;
    try {
      response = await _http.get(
        baseUri.resolve('participants/me/state'),
        headers: {
          'authorization': 'Bearer ${await _tokens.accessToken()}',
          'accept': 'application/json',
        },
      );
    } on Object catch (e) {
      throw IngestTransient('state fetch failed: $e');
    }

    switch (response.statusCode) {
      case 200:
        final fetched = ParticipantState.fromJson(
          (jsonDecode(response.body) as Map).cast<String, Object?>(),
        );
        final cached = current();
        // Responses can arrive out of order on a bad connection; an older one must not overwrite a
        // newer one, which is what the revision is for.
        if (cached != null && fetched.revision <= cached.revision) return cached;
        _write(fetched);
        return fetched;

      case 404:
        // Nothing computed yet. A 404 after a document has been seen is far more likely to be a
        // routing or deployment problem than a real deletion, so the cache is kept.
        return current();

      case 401:
        throw const IngestUnauthorized('state fetch rejected');

      case >= 500:
        throw IngestTransient('state fetch: ${response.statusCode}');

      default:
        throw IngestRefused(
          'state fetch: ${response.statusCode}',
          statusCode: response.statusCode,
        );
    }
  }

  void clear() {
    _cached = null;
    _db.transaction(() {
      _db.db.execute('DELETE FROM meta WHERE key = ?', [_cacheKey]);
    });
  }

  void _write(ParticipantState state) {
    _cached = state;
    _db.transaction(() {
      _db.writeMeta(_cacheKey, jsonEncode(state.toJson()));
    });
  }

  ParticipantState? _readCache() {
    final raw = _db.readMeta(_cacheKey);
    if (raw == null) return null;
    try {
      return ParticipantState.fromJson(
        (jsonDecode(raw) as Map).cast<String, Object?>(),
      );
    } on Object {
      // A cached document this build can no longer parse is discarded rather than crashing the app
      // on every launch after an upgrade.
      return null;
    }
  }
}
