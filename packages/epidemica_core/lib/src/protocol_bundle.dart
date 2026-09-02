import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

/// The modules this binary actually embeds.
///
/// A module set is fixed at build time (ADR-0001), so this is a compile-time fact about the app,
/// not configuration. It exists to be compared against what a study asks for.
@immutable
class ModuleRegistry {
  const ModuleRegistry(this.modules);

  /// Module identifiers, e.g. `proximity`, `instruments`.
  final Set<String> modules;

  /// Modules the bundle requires that this binary cannot provide.
  List<String> missingFor(ProtocolBundle bundle) =>
      [...bundle.requiredModules.where((m) => !modules.contains(m))]..sort();

  bool canService(ProtocolBundle bundle) => missingFor(bundle).isEmpty;
}

/// The study's configuration, as fetched from `protocol_url`.
///
/// Only the fields core needs are modelled. Module blocks are handed to modules as raw maps, so
/// adding a module never requires changing this class.
@immutable
class ProtocolBundle {
  const ProtocolBundle({
    required this.studyId,
    required this.title,
    required this.requiredModules,
    required this.raw,
  });

  final String studyId;
  final String title;

  /// Sorted, so an error message naming missing modules reads the same every time.
  final List<String> requiredModules;

  final Map<String, Object?> raw;

  /// `sha256:` followed by the hex digest of the exact bytes fetched.
  ///
  /// Computed over the bytes rather than over a re-encoding of the parsed object: two JSON
  /// documents that parse identically can serialise differently, and the hash has to identify
  /// what was actually served.
  static String hashOf(List<int> bytes) => 'sha256:${sha256.convert(bytes)}';

  static ProtocolBundle parse(List<int> bytes) {
    final json = (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();
    final modules = (json['modules'] as Map?)?.cast<String, Object?>() ?? const {};
    return ProtocolBundle(
      studyId: json['study_id']! as String,
      title: json['title'] as String? ?? '',
      // Declaring a module and configuring it are the same act, so the bundle cannot name one it
      // forgot to configure or configure one it never declared.
      requiredModules: modules.keys.toList()..sort(),
      raw: json,
    );
  }

  /// The configuration block for one module, or an empty map.
  Map<String, Object?> configFor(String module) =>
      ((raw['modules'] as Map?)?[module] as Map?)?.cast<String, Object?>() ?? const {};

  /// Floor between sync attempts, when the study states one.
  Duration? get minSyncInterval {
    final seconds = ((raw['sync'] as Map?)?['min_interval_seconds'] as num?)?.toInt();
    return seconds == null ? null : Duration(seconds: seconds);
  }

  Map<String, Object?> get _health =>
      (raw['health'] as Map?)?.cast<String, Object?>() ?? const {};

  /// Whether devices report when their modules were actually collecting.
  ///
  /// On unless the study says otherwise: a dataset that cannot tell "met nobody" from "was not
  /// listening" is defective whether or not anyone notices, and the cost is one observation per
  /// module per interval.
  bool get healthReportingEnabled => _health['enabled'] as bool? ?? true;

  Duration get healthInterval {
    final seconds = (_health['interval_seconds'] as num?)?.toInt();
    return seconds == null ? const Duration(hours: 1) : Duration(seconds: seconds);
  }

  /// The server-side model this study runs, if any. Absent for studies that only collect.
  Map<String, Object?>? get twin => (raw['twin'] as Map?)?.cast<String, Object?>();

  Map<String, Object?> get _schedule =>
      (raw['schedule'] as Map?)?.cast<String, Object?>() ?? const {};

  /// When day 1 begins, or null for a study with no schedule.
  ///
  /// Lets an app that joined early say when play starts rather than showing an unexplained blank:
  /// codes are handed out before a study opens, and a participant who joined in good time should
  /// not be left wondering whether something is broken.
  DateTime? get startsAt {
    final value = _schedule['starts_at'];
    return value is String ? DateTime.tryParse(value)?.toUtc() : null;
  }

  /// How many days the study runs, or null for open-ended collection.
  int? get scheduledDays => (_schedule['days'] as num?)?.toInt();
}
