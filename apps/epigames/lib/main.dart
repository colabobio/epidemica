import 'dart:io';

import 'package:epidemica_core/epidemica_core.dart';
import 'package:epidemica_proximity_module/epidemica_proximity_module.dart';
import 'package:epidemica_survey/epidemica_survey.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'src/app.dart';

/// Where this institution's server lives.
///
/// Supplied at build time rather than compiled in:
///   flutter build apk --dart-define=EPIDEMICA_SERVER=https://study.example.org/v1/
const String _serverUrl = String.fromEnvironment(
  'EPIDEMICA_SERVER',
  defaultValue: 'http://10.0.2.2:4000/v1/',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final directory = await getApplicationDocumentsDirectory();
  final db = EpidemicaDatabase.open(p.join(directory.path, 'epidemica.db'));

  final proximity = ProximityModule();

  // Fetches its own definitions, so it needs the study server and a token for it. Declared before
  // the controller because it borrows one, and created by the controller because it is a module.
  late final StudyController controller;
  final survey = SurveyModule(
    source: HttpInstrumentSource(
      baseUri: Uri.parse(_serverUrl),
      authorization: () => controller.accessToken(),
    ),
  );

  controller = StudyController(
    baseUri: Uri.parse(_serverUrl),
    // The module set of this binary. Everything else is decided by the bundle.
    modules: [proximity, survey],
    db: db,
    secrets: PlatformSecretStore(),
    platform: Platform.isIOS ? 'ios' : 'android',
  );

  // A background wake is the platform saying "now is a safe time to upload". Whether anything
  // actually happens is `syncThrottled`'s call, which applies its own floor — and the study's own
  // `sync.min_interval_seconds`, if it declares one — so this callback cannot fire more often than
  // either allows no matter how often the platform offers.
  proximity.onSyncDue = () => controller.syncThrottled();

  await controller.initialize();

  runApp(EpigamesApp(controller: controller, survey: survey));
}
