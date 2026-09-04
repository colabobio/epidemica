import 'package:meta/meta.dart';

/// How an item is answered.
///
/// Closed responses only. There is no open type here and none in the contract, which is what keeps
/// the observation store pseudonymous by construction rather than by policy: free text can carry
/// identifiers no schema is able to screen.
enum ItemType {
  singleChoice,
  multiChoice,
  likert;

  static ItemType? parse(String? raw) => switch (raw) {
    'single_choice' => ItemType.singleChoice,
    'multi_choice' => ItemType.multiChoice,
    'likert' => ItemType.likert,
    _ => null,
  };
}

/// One choice offered by a choice item.
@immutable
class ItemOption {
  const ItemOption({required this.value, required this.label});

  /// What is recorded. Stable across rewordings of [label], so improving the wording a participant
  /// reads does not change what the data means.
  final Object value;

  final String label;

  static ItemOption? parse(Object? raw) {
    if (raw is! Map) return null;
    final value = raw['value'];
    final label = raw['label'];
    if ((value is! String && value is! int) || label is! String || label.isEmpty) return null;
    return ItemOption(value: value as Object, label: label);
  }
}

/// The range a Likert item offers.
@immutable
class LikertScale {
  const LikertScale({required this.min, required this.max, this.minLabel, this.maxLabel});

  final int min;
  final int max;

  /// What the ends mean. A bare numeric scale is answered differently from an anchored one, so the
  /// labels are part of the instrument rather than decoration.
  final String? minLabel;
  final String? maxLabel;

  List<int> get values => [for (var v = min; v <= max; v++) v];

  static LikertScale? parse(Object? raw) {
    if (raw is! Map) return null;
    final min = raw['min'];
    final max = raw['max'];
    if (min is! int || max is! int || max <= min) return null;
    return LikertScale(
      min: min,
      max: max,
      minLabel: raw['min_label'] as String?,
      maxLabel: raw['max_label'] as String?,
    );
  }
}

/// One question.
@immutable
class InstrumentItem {
  const InstrumentItem({
    required this.id,
    required this.type,
    required this.prompt,
    this.help,
    this.required = false,
    this.options = const [],
    this.scale,
  });

  final String id;
  final ItemType type;
  final String prompt;
  final String? help;

  /// Whether the instrument refuses to move on. False by default: a participant who declines is
  /// recorded as having refused, which is a measurement, whereas one who is trapped abandons the
  /// instrument and takes the remaining answers with them.
  final bool required;

  final List<ItemOption> options;
  final LikertScale? scale;

  static InstrumentItem? parse(Object? raw) {
    if (raw is! Map) return null;

    final id = raw['item_id'];
    final type = ItemType.parse(raw['type'] as String?);
    final prompt = raw['prompt'];
    if (id is! String || id.isEmpty || type == null || prompt is! String || prompt.isEmpty) {
      return null;
    }

    final options = [for (final o in (raw['options'] as List? ?? const [])) ?ItemOption.parse(o)];
    final scale = LikertScale.parse(raw['scale']);

    // An item whose type promises something it does not carry is dropped rather than rendered
    // half-formed: a choice with nothing to choose is a question a participant cannot get past.
    final complete = switch (type) {
      ItemType.singleChoice || ItemType.multiChoice => options.length >= 2,
      ItemType.likert => scale != null,
    };
    if (!complete) return null;

    return InstrumentItem(
      id: id,
      type: type,
      prompt: prompt,
      help: raw['help'] as String?,
      required: raw['required'] as bool? ?? false,
      options: options,
      scale: scale,
    );
  }
}

/// A set of questions, versioned independently of the study bundle.
@immutable
class Instrument {
  const Instrument({
    required this.id,
    required this.version,
    required this.title,
    required this.items,
    this.description,
    this.language,
  });

  final String id;

  /// Semantic version of the questions. Carried onto every response, because pooling answers
  /// across revisions without knowing which is which is a quiet source of measurement error.
  final String version;

  final String title;
  final String? description;
  final String? language;
  final List<InstrumentItem> items;

  /// Reads a definition document, or null if it is not one this build can present.
  ///
  /// Refusing is better than rendering what it can: an instrument missing half its items would be
  /// answered, uploaded, and analysed as though the participant had seen the whole thing.
  static Instrument? parse(Map<String, Object?> raw) {
    final id = raw['instrument_id'];
    final version = raw['version'];
    final title = raw['title'];
    if (raw['instrument_version'] != '1.0') return null;
    if (id is! String || version is! String || title is! String || title.isEmpty) return null;

    final source = raw['items'];
    if (source is! List || source.isEmpty) return null;

    final items = [for (final item in source) InstrumentItem.parse(item)];
    if (items.any((i) => i == null)) return null;

    return Instrument(
      id: id,
      version: version,
      title: title,
      description: raw['description'] as String?,
      language: raw['language'] as String?,
      items: items.cast<InstrumentItem>(),
    );
  }
}
