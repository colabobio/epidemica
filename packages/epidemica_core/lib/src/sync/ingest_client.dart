import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'ingest_result.dart';

/// Supplies the bearer token, and knows how to get a fresh one.
abstract class AccessTokenSource {
  Future<String> accessToken();

  /// Called once after a 401 before the request is retried.
  Future<void> refresh();
}

/// Base class for conditions the sync loop must tell apart.
sealed class IngestException implements Exception {
  const IngestException(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The server asked us to slow down and said for how long.
class IngestRateLimited extends IngestException {
  const IngestRateLimited(this.retryAfter) : super('rate limited');
  final Duration? retryAfter;
}

/// 5xx or a transport failure. Worth retrying with backoff.
class IngestTransient extends IngestException {
  const IngestTransient(super.message, {this.statusCode});
  final int? statusCode;
}

/// The batch was too large. Halve it rather than retrying unchanged.
class IngestPayloadTooLarge extends IngestException {
  const IngestPayloadTooLarge() : super('batch too large');
}

/// Credentials are not valid even after a refresh. Retrying cannot help.
class IngestUnauthorized extends IngestException {
  const IngestUnauthorized(super.message);
}

/// 4xx other than 401/413/429. This build is sending something the server will never accept.
class IngestRefused extends IngestException {
  const IngestRefused(super.message, {required this.statusCode});
  final int statusCode;
}

/// Speaks the ingest API. Knows about HTTP and nothing about the outbox.
class IngestClient {
  IngestClient({
    required this.baseUri,
    required AccessTokenSource tokens,
    http.Client? httpClient,
  }) : _tokens = tokens,
       _http = httpClient ?? http.Client();

  final Uri baseUri;
  final AccessTokenSource _tokens;
  final http.Client _http;

  Future<IngestResult> upload(List<Map<String, Object?>> envelopes) async {
    final response = await _send(
      'POST',
      baseUri.resolve('observations'),
      body: {'observations': envelopes},
    );
    return IngestResult.fromJson(
      (jsonDecode(response.body) as Map).cast<String, Object?>(),
    );
  }

  Future<IngestWatermark> watermark() async {
    final response = await _send('GET', baseUri.resolve('observations/ack'));
    return IngestWatermark.fromJson(
      (jsonDecode(response.body) as Map).cast<String, Object?>(),
    );
  }

  Future<http.Response> _send(
    String method,
    Uri uri, {
    Map<String, Object?>? body,
    bool allowRefresh = true,
  }) async {
    final request = http.Request(method, uri)
      ..headers['authorization'] = 'Bearer ${await _tokens.accessToken()}'
      ..headers['accept'] = 'application/json';

    if (body != null) {
      // Envelopes repeat study_id, protocol_hash, subject and device_id on every observation, so a
      // batch compresses by an order of magnitude. ADR-0002 chose that repetition deliberately and
      // pays for it here rather than with a batch header.
      request.headers['content-type'] = 'application/json';
      request.headers['content-encoding'] = 'gzip';
      request.bodyBytes = gzip.encode(utf8.encode(jsonEncode(body)));
    }

    final http.Response response;
    try {
      response = await http.Response.fromStream(await _http.send(request));
    } on Object catch (e) {
      throw IngestTransient('transport failure: $e');
    }

    return switch (response.statusCode) {
      200 || 201 => response,
      401 when allowRefresh => await _retryAfterRefresh(method, uri, body),
      401 => throw const IngestUnauthorized('token rejected after refresh'),
      413 => throw const IngestPayloadTooLarge(),
      429 => throw IngestRateLimited(_retryAfter(response)),
      >= 500 => throw IngestTransient(
        'server error ${response.statusCode}',
        statusCode: response.statusCode,
      ),
      _ => throw IngestRefused(
        _detail(response),
        statusCode: response.statusCode,
      ),
    };
  }

  Future<http.Response> _retryAfterRefresh(
    String method,
    Uri uri,
    Map<String, Object?>? body,
  ) async {
    await _tokens.refresh();
    return _send(method, uri, body: body, allowRefresh: false);
  }

  /// `Retry-After` may be either a number of seconds or an HTTP date.
  static Duration? _retryAfter(http.Response response) {
    final raw = response.headers['retry-after'];
    if (raw == null) return null;

    final seconds = int.tryParse(raw.trim());
    if (seconds != null) return Duration(seconds: seconds);

    try {
      final until = HttpDate.parse(raw).toUtc();
      final delta = until.difference(DateTime.now().toUtc());
      return delta.isNegative ? Duration.zero : delta;
    } on FormatException {
      return null;
    }
  }

  /// RFC 9457 problem details, when the server sends them.
  static String _detail(http.Response response) {
    try {
      final problem = (jsonDecode(response.body) as Map).cast<String, Object?>();
      return '${response.statusCode}: ${problem['detail'] ?? problem['title'] ?? response.body}';
    } on Object {
      return '${response.statusCode}: ${response.body}';
    }
  }

  void close() => _http.close();
}
