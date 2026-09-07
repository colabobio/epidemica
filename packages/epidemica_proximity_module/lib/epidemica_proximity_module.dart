/// The proximity module, packaged as an app capability.
///
/// An app embeds this to be able to run proximity studies; whether it actually does, and how, is
/// decided by the protocol bundle. Kept out of `epidemica_core` because core defines the module
/// interface and must not depend on any implementation of it.
library;

export 'src/module_store_episode_store.dart';
export 'src/permissions.dart';
export 'src/proximity_module.dart';
