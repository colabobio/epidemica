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
/// Only the fields core needs are modelled. Module-specific blocks are handed to modules as raw
/// maps, so adding a module never requires changing this class.
@immutable
class ProtocolBundle {
  const ProtocolBundle({
    required this.studyId,
    required this.requiredModules,
    required this.raw,
  });

  final String studyId;
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
    return ProtocolBundle(
      studyId: json['study_id']! as String,
      requiredModules: [
        for (final m in (json['modules'] as List? ?? const [])) m! as String,
      ],
      raw: json,
    );
  }

  /// The configuration block for one module, or an empty map.
  Map<String, Object?> configFor(String module) =>
      (raw[module] as Map?)?.cast<String, Object?>() ?? const {};
}
