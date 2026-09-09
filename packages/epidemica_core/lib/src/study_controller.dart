import 'dart:async';
import 'dart:convert';

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
    required Uri baseUri,
    required this.modules,
    required EpidemicaDatabase db,
    required SecretStore secrets,
    required this.platform,
    http.Client? httpClient,
  }) : baseUri = _asDirectory(baseUri),
       _db = db,
       _http = httpClient ?? http.Client() {
    _identity = Identity(_db);
    _outbox = Outbox(_db);
    _clock = DeviceClock(_db);
    _tokens = TokenStore(baseUri: this.baseUri, secrets: secrets, httpClient: _http);
    _enrollments = EnrollmentService(
      baseUri: this.baseUri,
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
      client: IngestClient(baseUri: this.baseUri, tokens: _tokens, httpClient: _http),
    );
    _states = StateChannel(baseUri: this.baseUri, db: _db, tokens: _tokens, httpClient: _http);
    _throttle = SyncThrottle(floor: syncFloor);
  }

  /// Always ends in a slash.
  ///
  /// Every endpoint is built with [Uri.resolve], which treats a base without a trailing slash as
  /// naming a file and replaces the last segment: `.../v1` + `enrollments` gives `.../enrollments`,
  /// silently dropping the API prefix. The server then has no route, returns 404, and the client
  /// reports it as an unknown join code — a configuration mistake wearing a data mistake's clothes.
  final Uri baseUri;

  static Uri _asDirectory(Uri uri) =>
      uri.path.endsWith('/') ? uri : uri.replace(path: '${uri.path}/');
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
  late final StateChannel _states;
  late final SyncThrottle _throttle;

  /// The shortest interval between syncs a platform trigger can produce, whatever a study asks.
  ///
  /// Background wakes are offers rather than a schedule, and on iOS they arrive on a BLE detection
  /// — so in a crowded room they arrive constantly. A study's own `sync.min_interval_seconds` can
  /// extend this but never shorten it: how hard a phone may be worked is a property of the device,
  /// not of the research question.
  static const Duration syncFloor = Duration(minutes: 5);

  Enrollment? _enrollment;
  final Set<String> _running = {};
  final Map<String, ModuleStatus> _moduleStatus = {};
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

  /// The last state document the server computed for this participant, or null if none ever was.
  ///
  /// Never synthesised: an invented "you are healthy" is indistinguishable from a measured one.
  ParticipantState? get participantState => _states.current(expectedSubject: _enrollment?.subject);

  /// What each running module reports about itself right now.
  ///
  /// Local and immediate, unlike the state document. A phone knows its own radio is off without
  /// asking anyone, and a participant who has just turned Bluetooth off should not have to wait
  /// for a server computation to be told what their own phone is doing.
  Map<String, ModuleStatus> get moduleStatus => Map.unmodifiable(_moduleStatus);

  /// A bearer token for the study server.
  ///
  /// For a module that has to fetch something of its own, such as a definition the bundle only
  /// points at. Refreshes when it is close to expiring, like every other request.
  Future<String> accessToken() => _tokens.accessToken();

  /// Asks every running module how it is doing. Notifies only when something changed, so this can
  /// be polled often without rebuilding the screen on every tick of a timer.
  Future<void> refreshModuleStatus() async {
    var changed = false;

    for (final module in modules) {
      if (!_running.contains(module.id)) continue;

      ModuleStatus status;
      try {
        status = await module.status();
      } on Object catch (e) {
        status = ModuleStatus(ModuleState.stopped, detail: '$e');
      }

      if (_moduleStatus[module.id]?.state != status.state) {
        _moduleStatus[module.id] = status;
        changed = true;
      }
    }

    if (changed) notifyListeners();
  }

  /// Asks the server for the current state. Swallows transport failure, because a stale document
  /// the participant can see is more use than an error they cannot act on.
  Future<void> refreshState() async {
    try {
      await _states.refresh();
    } on Object catch (e) {
      _message = '$e';
    }
    notifyListeners();
  }

  /// Posts a study-defined action, with a body this package does not interpret.
  ///
  /// The upward mirror of the state channel: as opaque here as an observation payload is to the
  /// outbox, so that one study's vocabulary never reaches the platform.
  Future<bool> postAction(Map<String, Object?> body) async {
    try {
      final response = await _http.post(
        baseUri.resolve('participants/me/actions'),
        headers: {
          'authorization': 'Bearer ${await _tokens.accessToken()}',
          'content-type': 'application/json',
        },
        body: jsonEncode(body),
      );
      if (response.statusCode != 200) {
        _message = 'That did not go through. Try again in a moment.';
        notifyListeners();
        return false;
      }
    } on Object {
      _message = 'No connection. Try again when you are online.';
      notifyListeners();
      return false;
    }

    await refreshState();
    return true;
  }

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

      // A study may publish a starting state at enrolment, and waiting for the host's next poll to
      // discover it leaves the participant looking at a screen that says nothing is known yet.
      // Failure is ignored rather than reported: the join worked, and the poll will retry.
      try {
        await _states.refresh();
      } on Object {
        // Deliberately empty.
      }
      notifyListeners();
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
            store: DatabaseModuleStore(db: _db, moduleId: module.id),
            studyStartsAt: enrollment.bundle.startsAt,
            requestSync: _requestSync,
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
        modules: [
          for (final m in modules)
            if (_running.contains(m.id)) m,
        ],
        interval: enrollment.bundle.healthInterval,
        recorderFor: (moduleId) =>
            recorderFor(outbox: _outbox, enrollment: enrollment, clock: _clock, module: moduleId),
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

  /// Syncs only if enough time has passed since the last one, and says whether it did.
  ///
  /// For triggers that fire when the platform decides rather than when anyone chose: a background
  /// wake, a service tick. [sync] is for a schedule somebody owns; this is for everything that
  /// could otherwise fire as fast as a device sees another device.
  Future<bool> syncThrottled() => _throttle.run(sync, _enrollment?.bundle.minSyncInterval);

  /// The shortest interval a platform trigger can currently produce a sync at.
  ///
  /// [syncFloor], extended by the study's own `sync.min_interval_seconds` when it declares a longer
  /// one. Exposed so an interface can say how often a device actually uploads rather than implying
  /// it is continuous.
  Duration get effectiveSyncFloor => _throttle.effectiveFloor(_enrollment?.bundle.minSyncInterval);

  /// What a module is handed. Nothing may propagate out of it: a module offering an upload
  /// opportunity is not making a request that can fail, and a wake that arrives while the network
  /// is down must not become an unhandled error in a stream callback.
  void _requestSync() {
    unawaited(syncThrottled().catchError((Object _) => false));
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
    _moduleStatus.clear();

    await _tokens.clear();
    _states.clear();
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
