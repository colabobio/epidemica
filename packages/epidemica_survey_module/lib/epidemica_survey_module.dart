/// The survey module, packaged as an app capability.
///
/// Adapts `epidemica_survey` to the platform: it owns the schedule, the record of what has been
/// answered, and the call that puts a response in the outbox. Kept out of `epidemica_survey` so
/// that the instrument model, the schedule and the response can be read, rendered and tested
/// without an outbox, tokens or a database — the same split the proximity stack uses, and for the
/// same reason.
library;

export 'src/survey_module.dart';
