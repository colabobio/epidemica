import 'dart:io';

import 'package:epidemica_core/epidemica_core.dart';
import 'package:epidemica_proximity_module/epidemica_proximity_module.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'src/app.dart';

/// Where this institution's server lives.
///
/// Supplied at build time rather than compiled in, so one source tree produces the binaries of
/// however many institutions deploy it:
///   flutter build apk --dart-define=EPIDEMICA_SERVER=https://study.example.org/v1/
const String _serverUrl = String.fromEnvironment(
  'EPIDEMICA_SERVER',
  defaultValue: 'http://10.0.2.2:4000/v1/',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final directory = await getApplicationDocumentsDirectory();
  final db = EpidemicaDatabase.open(p.join(directory.path, 'epidemica.db'));

  final controller = StudyController(
    baseUri: Uri.parse(_serverUrl),
    // The module set of this binary. Everything else is decided by the bundle.
    modules: [ProximityModule()],
    db: db,
    secrets: PlatformSecretStore(),
    platform: Platform.isIOS ? 'ios' : 'android',
  );
  await controller.initialize();

  runApp(EpidemicaApp(controller: controller));
}
