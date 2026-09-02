import 'package:epidemica_core/epidemica_core.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;


/// What the participant is shown, and what the app is actually doing.
enum StudyState { notEnrolled, enrolled, collecting, refused }

/// Ties identity, enrollment, modules and sync together.
///
/// This is the whole of Tier 1 in one class: the binary embeds a fixed set of modules, the bundle
/// says which of them a study uses and how, and nothing here knows what `contactlog` is.
class StudyController extends ChangeNotifier {
  StudyController({
    required this.baseUri,
    required this.modules,
    required EpidemicaDatabase db,
    required SecretStore secrets,
    required this.platform,
    http.Client? httpClient,
  }) : _db = db,
       _http = httpClient ?? http.Client() {
    _identity = Identity(_db);
    _outbox = Outbox(_db);
    _clock = DeviceClock(_db);
    _tokens = TokenStore(baseUri: baseUri, secrets: secrets, httpClient: _http);
    _enrollments = EnrollmentService(
      baseUri: baseUri,
      db: _db,
      identity: _identity,
      tokens: _tokens,
      // Derived from what is embedded rather than hand-maintained, so the registry cannot claim a
      // module this binary does not actually contain.
      registry: ModuleRegistry({for (final m in modules) m.id}),
      platform: platform,
      httpClient: _http,
    );
    _sync = SyncService(
      outbox: _outbox,
      clock: _clock,
      client: IngestClient(baseUri: baseUri, tokens: _tokens, httpClient: _http),
    );
  }

  final Uri baseUri;
  final List<EmbeddedModule> modules;
  final String platform;

  final EpidemicaDatabase _db;
  final http.Client _http;

  late final Identity _identity;
  late final Outbox _outbox;
  late final DeviceClock _clock;
  late final TokenStore _tokens;
  late final EnrollmentService _enrollments;
  late final SyncService _sync;

  Enrollment? _enrollment;
  final Set<String> _running = {};
  ModuleHealthReporter? _health;
  StudyState _state = StudyState.notEnrolled;
  String? _message;
  DateTime? _lastSyncAt;

  Enrollment? get enrollment => _enrollment;
  StudyState get state => _state;

  /// Human-readable explanation of the current state, for the participant.
  String? get message => _message;

  DateTime? get lastSyncAt => _lastSyncAt;
  int get pendingObservations => _outbox.pendingCount();
  int get deadLetterCount => _outbox.deadLetters().length;
  int? get clockOffsetMs => _clock.offsetMs;
  String get subject => _identity.subject;
  Set<String> get runningModules => Set.unmodifiable(_running);

  /// Resumes a study joined in an earlier session.
  Future<void> initialize() async {
    final existing = _enrollments.current();
    if (existing == null) {
      _state = StudyState.notEnrolled;
      notifyListeners();
      return;
    }
    _enrollment = existing;
    _state = StudyState.enrolled;
    notifyListeners();
    await _activate(existing);
  }

  /// Joins a study with a code, and starts collecting if this binary can service it.
  Future<void> join(String joinCode) async {
    try {
      final enrollment = await _enrollments.enroll(joinCode.trim());
      _enrollment = enrollment;
      _state = StudyState.enrolled;
      _message = null;
      notifyListeners();
      await _activate(enrollment);
    } on EnrollmentException catch (e) {
      _state = StudyState.refused;
      _message = _explain(e);
      notifyListeners();
    }
  }

  /// Starts every module the bundle names.
  ///
  /// Enrollment has already refused a bundle naming a module this binary lacks, so anything
  /// reaching here is known to be serviceable.
  Future<void> _activate(Enrollment enrollment) async {
    for (final module in modules) {
      if (!enrollment.bundle.requiredModules.contains(module.id)) continue;
      try {
        await module.start(
          ModuleContext(
            config: enrollment.bundle.configFor(module.id),
            studyId: enrollment.studyId,
            subject: enrollment.subject,
            record: recorderFor(
              outbox: _outbox,
              enrollment: enrollment,
              clock: _clock,
              module: module.id,
            ),
          ),
        );
        _running.add(module.id);
      } on Object catch (e) {
        _message = '${module.id}: $e';
      }
    }
    _state = _running.isEmpty ? StudyState.enrolled : StudyState.collecting;

    if (_running.isNotEmpty && enrollment.bundle.healthReportingEnabled) {
      // Coverage has to be stated positively: a study that infers exposure from an absence of
      // contacts cannot otherwise tell "met nobody" from "was not listening". Declared in the
      // bundle, so a study that has no use for it pays nothing.
      _health = ModuleHealthReporter(
        modules: [for (final m in modules) if (_running.contains(m.id)) m],
        interval: enrollment.bundle.healthInterval,
        recorderFor: (moduleId) => recorderFor(
          outbox: _outbox,
          enrollment: enrollment,
          clock: _clock,
          module: moduleId,
        ),
      )..start();
    }

    notifyListeners();
  }

  Future<SyncReport> sync() async {
    final report = await _sync.syncOnce();
    _lastSyncAt = DateTime.now().toUtc();
    if (report.error != null) _message = '${report.error}';
    notifyListeners();
    return report;
  }

  /// Stops collection and removes everything held locally.
  ///
  /// Observations already delivered are the server's to erase; what this can promise is that the
  /// device keeps nothing, including anything queued but not yet sent.
  Future<void> withdraw() async {
    // Close the coverage window before stopping, so the final period is not left looking
    // unobserved merely because collection ended tidily.
    await _health?.flush();
    _health?.stop();
    _health = null;

    for (final module in modules) {
      await module.stop();
    }
    _running.clear();

    await _tokens.clear();
    _db.transaction(() {
      _db.db.execute('DELETE FROM outbox');
      _db.db.execute('DELETE FROM dead_letter');
      // Identity goes too: keeping the pseudonym would let a later enrollment be linked to this
      // one, which is exactly what withdrawing is meant to prevent.
      _db.db.execute('DELETE FROM meta');
      _db.db.execute("DELETE FROM sqlite_sequence WHERE name = 'outbox'");
    });

    _enrollment = null;
    _state = StudyState.notEnrolled;
    _message = null;
    _lastSyncAt = null;
    notifyListeners();
  }

  static String _explain(EnrollmentException e) => switch (e.failure) {
    EnrollmentFailure.unsupportedModules =>
      'This study needs a newer version of the app. It uses '
          '${e.missingModules.join(' and ')}, which this version cannot collect.',
    EnrollmentFailure.unknownJoinCode => 'That code did not match an open study.',
    EnrollmentFailure.alreadyEnrolled => 'This device is already enrolled in a study.',
    EnrollmentFailure.bundleHashMismatch =>
      'The study configuration did not match what the server described. Nothing was started.',
    EnrollmentFailure.bundleUnavailable => 'The study configuration could not be downloaded.',
    EnrollmentFailure.network => 'No connection. Try again when you are online.',
    EnrollmentFailure.server => 'The study server is having trouble. Try again shortly.',
  };

  @override
  void dispose() {
    _http.close();
    super.dispose();
  }
}
