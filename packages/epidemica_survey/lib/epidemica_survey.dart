/// Scheduled instruments for Epidemica study apps.
///
/// A study names instruments and when to ask them; the definitions live and version outside the
/// bundle, so a reworded question does not re-register the study. Responses go up as ordinary
/// observations against `observations/instruments/survey_response`.
///
/// Nothing here knows about an outbox, a token or a server: an instrument can be parsed, scheduled,
/// rendered and answered with none of them present. `epidemica_survey_module` is what turns that
/// into a study capability.
library;

export 'src/instrument.dart';
export 'src/instrument_source.dart';
export 'src/response.dart';
export 'src/schedule.dart';
export 'src/survey_screen.dart';
