import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'instrument.dart';
import 'schedule.dart';

/// Where instrument definitions come from.
///
/// An interface so the module never chooses a transport, and so tests can supply questions without
/// a server.
abstract class InstrumentSource {
  Future<Instrument> fetch(ScheduledInstrument entry);
}

class InstrumentUnavailable implements Exception {
  const InstrumentUnavailable(this.message);

  final String message;

  @override
  String toString() => 'InstrumentUnavailable: $message';
}

/// Fetches definitions over HTTP and checks them against the digest the bundle pinned.
///
/// The digest is computed over the exact bytes served, not over a re-encoding of the parsed
/// document: two JSON texts that parse identically can serialise differently, and the hash has to
/// identify what was actually delivered. Same rule as the protocol bundle, for the same reason —
/// questions a study did not author must never reach a participant.
class HttpInstrumentSource implements InstrumentSource {
  HttpInstrumentSource({
    required this.baseUri,
    this.authorization,
    http.Client? httpClient,
    Map<String, String>? cache,
  }) : _http = httpClient ?? http.Client(),
       _cache = cache ?? {};

  /// The API base a relative definition URL resolves against.
  final Uri baseUri;

  /// Supplies a bearer token, for definitions the study server serves behind one.
  final Future<String> Function()? authorization;

  final http.Client _http;
  final Map<String, String> _cache;

  @override
  Future<Instrument> fetch(ScheduledInstrument entry) async {
    final cached = _cache[entry.key];
    if (cached != null) return _parse(entry, utf8.encode(cached));

    final token = await authorization?.call();

    final http.Response response;
    try {
      response = await _http.get(
        baseUri.resolveUri(entry.url),
        headers: {if (token != null) 'authorization': 'Bearer $token'},
      );
    } on Object catch (e) {
      throw InstrumentUnavailable('could not fetch ${entry.key}: $e');
    }

    if (response.statusCode != 200) {
      throw InstrumentUnavailable('${entry.key}: HTTP ${response.statusCode}');
    }

    final instrument = _parse(entry, response.bodyBytes);
    _cache[entry.key] = utf8.decode(response.bodyBytes);
    return instrument;
  }

  Instrument _parse(ScheduledInstrument entry, List<int> bytes) {
    final digest = 'sha256:${sha256.convert(bytes)}';
    if (digest != entry.sha256) {
      throw InstrumentUnavailable('${entry.key}: expected ${entry.sha256}, served $digest');
    }

    final Map<String, Object?> decoded;
    try {
      decoded = (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();
    } on Object catch (e) {
      throw InstrumentUnavailable('${entry.key}: not a definition document ($e)');
    }

    final instrument = Instrument.parse(decoded);
    if (instrument == null) {
      throw InstrumentUnavailable('${entry.key}: this build cannot present that definition');
    }
    if (instrument.id != entry.instrumentId || instrument.version != entry.version) {
      throw InstrumentUnavailable(
        '${entry.key}: served ${instrument.id}@${instrument.version} instead',
      );
    }

    return instrument;
  }
}
