import 'dart:convert';

import 'package:epidemica_core/epidemica_core.dart';
import 'package:epidemica_proximity/epidemica_proximity.dart';

/// Keeps encounters that are still open in the module's own durable store.
///
/// The adapter lives here because this is the only package allowed to see both halves:
/// `epidemica_core` must not know that a proximity module exists, and `epidemica_proximity` must
/// not depend on storage. Without it an episode exists only in memory until proximity ends, and a
/// process kill mid-encounter discards it — a loss that falls preferentially on the longest
/// encounters, which is exactly the tail of the contact-duration distribution a transmission study
/// exists to measure.
class ModuleStoreEpisodeStore implements OpenEpisodeStore {
  const ModuleStoreEpisodeStore(this._store);

  static const String key = 'open_episodes';

  final ModuleStore _store;

  @override
  Future<Map<String, Object?>?> load() async {
    final raw = _store.read(key);
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as Map).cast<String, Object?>();
    } on Object {
      // A snapshot this build can no longer read costs one encounter; refusing to start would cost
      // the study everything after it.
      return null;
    }
  }

  @override
  Future<void> save(Map<String, Object?> snapshot) async =>
      _store.write(key, jsonEncode(snapshot));

  @override
  Future<void> clear() async => _store.delete(key);
}
