import '../db/database.dart';
import 'embedded_module.dart';

/// A [ModuleStore] on the device database, with each module's keys kept apart.
///
/// The namespace is not a courtesy. Two modules that could overwrite each other's keys would fail
/// in a way that only appears when a study happens to enable both, which is the worst time to
/// discover it.
class DatabaseModuleStore implements ModuleStore {
  DatabaseModuleStore({required EpidemicaDatabase db, required String moduleId})
    : _db = db,
      _prefix = 'module:$moduleId:';

  final EpidemicaDatabase _db;
  final String _prefix;

  @override
  String? read(String key) => _db.readMeta('$_prefix$key');

  @override
  void write(String key, String value) {
    _db.transaction(() => _db.writeMeta('$_prefix$key', value));
  }

  @override
  void delete(String key) {
    _db.transaction(() {
      _db.db.execute('DELETE FROM meta WHERE key = ?', ['$_prefix$key']);
    });
  }
}
