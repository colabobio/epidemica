import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'db/database.dart';
import 'identity.dart';
import 'protocol_bundle.dart';
import 'tokens.dart';

/// Why an enrollment attempt did not produce a usable study.
enum EnrollmentFailure {
  /// No open study matches the code. Deliberately not distinguished from closed or full, so codes
  /// cannot be enumerated.
  unknownJoinCode,

  /// This pseudonym is already enrolled with a different device.
  alreadyEnrolled,

  /// The bundle could not be fetched.
  bundleUnavailable,

  /// The fetched bundle does not hash to what enrollment said was in force.
  bundleHashMismatch,

  /// The study needs a module this binary does not embed.
  unsupportedModules,

  network,
  server,
}

class EnrollmentException implements Exception {
  const EnrollmentException(this.failure, this.message, {this.missingModules = const []});

  final EnrollmentFailure failure;
  final String message;

  /// Populated for [EnrollmentFailure.unsupportedModules].
  final List<String> missingModules;

  @override
  String toString() => 'EnrollmentException(${failure.name}): $message';
}

/// A study this device is enrolled in and can actually service.
@immutable
class Enrollment {
  const Enrollment({
    required this.studyId,
    required this.subject,
    required this.deviceId,
    required this.protocolHash,
    required this.bundle,
    this.arm,
  });

  final String studyId;
  final String subject;
  final String deviceId;

  /// Stamped on every observation recorded under this bundle.
  final String protocolHash;

  final ProtocolBundle bundle;
  final String? arm;
}

/// Joins a study.
class EnrollmentService {
  EnrollmentService({
    required this.baseUri,
    required EpidemicaDatabase db,
    required Identity identity,
    required TokenStore tokens,
    required ModuleRegistry registry,
    required this.platform,
    http.Client? httpClient,
    DateTime Function()? now,
    this.appVersion,
    this.locale,
  }) : _db = db,
       _identity = identity,
       _tokens = tokens,
       _registry = registry,
       _http = httpClient ?? http.Client(),
       _now = now ?? DateTime.now;

  static const String studyIdKey = 'study_id';
  static const String protocolHashKey = 'protocol_hash';
  static const String armKey = 'study_arm';
  static const String bundleKey = 'protocol_bundle';

  final Uri baseUri;
  final EpidemicaDatabase _db;
  final Identity _identity;
  final TokenStore _tokens;
  final ModuleRegistry _registry;
  final http.Client _http;
  final DateTime Function() _now;

  /// `ios`, `android` or `web`.
  final String platform;
  final String? appVersion;
  final String? locale;

  /// Exchanges a join code for a study this device can service.
  ///
  /// The module check happens after the server call, because the bundle's location is only known
  /// once enrollment returns it. That ordering is forced by the API, and it has a consequence
  /// worth stating plainly: a study whose modules this binary lacks leaves an enrollment record on
  /// the server that will never produce data. Failing loudly here is the best available outcome —
  /// the alternative, enrolling anyway, is discovered at analysis time when the collection window
  /// has already passed.
  Future<Enrollment> enroll(String joinCode) async {
    final response = await _post(joinCode);
    final body = (jsonDecode(response.body) as Map).cast<String, Object?>();

    final protocolHash = body['protocol_hash']! as String;
    final bundleBytes = await _fetchBundle(body['protocol_url']! as String);

    final actualHash = ProtocolBundle.hashOf(bundleBytes);
    if (actualHash != protocolHash) {
      // The hash is stamped on every observation. Accepting a mismatch would label a study's whole
      // dataset with a protocol version it was not collected under.
      throw EnrollmentException(
        EnrollmentFailure.bundleHashMismatch,
        'bundle hashed to $actualHash but enrollment said $protocolHash',
      );
    }

    final bundle = ProtocolBundle.parse(bundleBytes);
    final missing = _registry.missingFor(bundle);
    if (missing.isNotEmpty) {
      throw EnrollmentException(
        EnrollmentFailure.unsupportedModules,
        'this build does not embed: ${missing.join(', ')}',
        missingModules: missing,
      );
    }

    await _tokens.save(
      StudyTokens(
        accessToken: body['access_token']! as String,
        expiresAt: _now().toUtc().add(
          Duration(seconds: (body['expires_in']! as num).toInt()),
        ),
        refreshToken: body['refresh_token'] as String?,
      ),
    );

    final enrollment = Enrollment(
      studyId: body['study_id']! as String,
      subject: body['subject']! as String,
      deviceId: _identity.deviceId,
      protocolHash: protocolHash,
      bundle: bundle,
      arm: body['arm'] as String?,
    );
    _persist(enrollment, bundleBytes);
    return enrollment;
  }

  /// The study this device is already enrolled in, if any.
  Enrollment? current() {
    final studyId = _db.readMeta(studyIdKey);
    final protocolHash = _db.readMeta(protocolHashKey);
    final bundle = _db.readMeta(bundleKey);
    if (studyId == null || protocolHash == null || bundle == null) return null;

    return Enrollment(
      studyId: studyId,
      subject: _identity.subject,
      deviceId: _identity.deviceId,
      protocolHash: protocolHash,
      bundle: ProtocolBundle.parse(utf8.encode(bundle)),
      arm: _db.readMeta(armKey),
    );
  }

  void _persist(Enrollment enrollment, List<int> bundleBytes) {
    _db.transaction(() {
      _db.writeMeta(studyIdKey, enrollment.studyId);
      _db.writeMeta(protocolHashKey, enrollment.protocolHash);
      _db.writeMeta(bundleKey, utf8.decode(bundleBytes));
      if (enrollment.arm != null) _db.writeMeta(armKey, enrollment.arm!);
    });
  }

  Future<http.Response> _post(String joinCode) async {
    final http.Response response;
    try {
      response = await _http.post(
        baseUri.resolve('enrollments'),
        headers: {'content-type': 'application/json', 'accept': 'application/json'},
        body: jsonEncode({
          'join_code': joinCode,
          'subject': _identity.subject,
          'device_id': _identity.deviceId,
          'platform': platform,
          if (appVersion != null) 'app_version': appVersion,
          if (locale != null) 'locale': locale,
        }),
      );
    } on Object catch (e) {
      throw EnrollmentException(EnrollmentFailure.network, '$e');
    }

    return switch (response.statusCode) {
      201 => response,
      404 => throw const EnrollmentException(
        EnrollmentFailure.unknownJoinCode,
        'no open study matches that code',
      ),
      409 => throw const EnrollmentException(
        EnrollmentFailure.alreadyEnrolled,
        'this pseudonym is already enrolled with a different device',
      ),
      _ => throw EnrollmentException(
        EnrollmentFailure.server,
        'enrollment failed: ${response.statusCode}',
      ),
    };
  }

  Future<List<int>> _fetchBundle(String url) async {
    try {
      final response = await _http.get(Uri.parse(url));
      if (response.statusCode != 200) {
        throw EnrollmentException(
          EnrollmentFailure.bundleUnavailable,
          'bundle fetch returned ${response.statusCode}',
        );
      }
      return response.bodyBytes;
    } on EnrollmentException {
      rethrow;
    } on Object catch (e) {
      throw EnrollmentException(EnrollmentFailure.bundleUnavailable, '$e');
    }
  }
}
