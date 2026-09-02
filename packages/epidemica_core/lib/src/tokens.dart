import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'sync/ingest_client.dart';

/// Somewhere to keep secrets. Abstracted so tokens can be tested without a platform channel, and
/// so a host with its own keystore can substitute one.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Keychain on iOS, EncryptedSharedPreferences on Android.
class PlatformSecretStore implements SecretStore {
  PlatformSecretStore([FlutterSecureStorage? storage])
    : _storage = storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
            iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
          );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// For tests, and for nothing else.
class InMemorySecretStore implements SecretStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

@immutable
class StudyTokens {
  const StudyTokens({
    required this.accessToken,
    required this.expiresAt,
    this.refreshToken,
  });

  final String accessToken;
  final DateTime expiresAt;
  final String? refreshToken;

  Map<String, Object?> toJson() => {
    'access_token': accessToken,
    'expires_at': expiresAt.toUtc().toIso8601String(),
    'refresh_token': refreshToken,
  };

  static StudyTokens fromJson(Map<String, Object?> json) => StudyTokens(
    accessToken: json['access_token']! as String,
    expiresAt: DateTime.parse(json['expires_at']! as String).toUtc(),
    refreshToken: json['refresh_token'] as String?,
  );
}

/// Raised when the refresh token is gone or revoked and the device must enrol again.
class ReEnrollmentRequired implements Exception {
  const ReEnrollmentRequired(this.message);
  final String message;

  @override
  String toString() => 'ReEnrollmentRequired: $message';
}

/// Holds the study tokens and keeps the access token fresh.
///
/// Access tokens are short-lived so a leaked one has a small blast radius; the refresh token is
/// long-lived but revocable per device, which is what lets one installation be cut off without
/// disturbing a study.
class TokenStore implements AccessTokenSource {
  TokenStore({
    required this.baseUri,
    required SecretStore secrets,
    http.Client? httpClient,
    DateTime Function()? now,
  }) : _secrets = secrets,
       _http = httpClient ?? http.Client(),
       _now = now ?? DateTime.now;

  static const String storageKey = 'epidemica.study_tokens';

  /// Refresh this far ahead of expiry, so a request never races the boundary.
  static const Duration refreshMargin = Duration(minutes: 2);

  final Uri baseUri;
  final SecretStore _secrets;
  final http.Client _http;
  final DateTime Function() _now;

  StudyTokens? _cached;

  Future<StudyTokens?> read() async {
    if (_cached != null) return _cached;
    final raw = await _secrets.read(storageKey);
    if (raw == null) return null;
    return _cached = StudyTokens.fromJson(
      (jsonDecode(raw) as Map).cast<String, Object?>(),
    );
  }

  Future<void> save(StudyTokens tokens) async {
    _cached = tokens;
    await _secrets.write(storageKey, jsonEncode(tokens.toJson()));
  }

  Future<void> clear() async {
    _cached = null;
    await _secrets.delete(storageKey);
  }

  @override
  Future<String> accessToken() async {
    final tokens = await read();
    if (tokens == null) {
      throw const ReEnrollmentRequired('no tokens stored');
    }
    if (_now().toUtc().isAfter(tokens.expiresAt.subtract(refreshMargin))) {
      await refresh();
      return (await read())!.accessToken;
    }
    return tokens.accessToken;
  }

  @override
  Future<void> refresh() async {
    final current = await read();
    final refreshToken = current?.refreshToken;
    if (refreshToken == null) {
      throw const ReEnrollmentRequired('no refresh token stored');
    }

    final response = await _http.post(
      baseUri.resolve('tokens'),
      headers: {'content-type': 'application/json', 'accept': 'application/json'},
      body: jsonEncode({'grant_type': 'refresh_token', 'refresh_token': refreshToken}),
    );

    if (response.statusCode == 401) {
      // Revoked or expired. Keeping the dead token would only produce a retry loop.
      await clear();
      throw const ReEnrollmentRequired('refresh token rejected');
    }
    if (response.statusCode != 200) {
      throw IngestTransient('token refresh failed: ${response.statusCode}');
    }

    final body = (jsonDecode(response.body) as Map).cast<String, Object?>();
    await save(
      StudyTokens(
        accessToken: body['access_token']! as String,
        expiresAt: _now().toUtc().add(
          Duration(seconds: (body['expires_in']! as num).toInt()),
        ),
        // A rotating server returns a new refresh token; one that does not, keeps the old.
        refreshToken: body['refresh_token'] as String? ?? refreshToken,
      ),
    );
  }
}
