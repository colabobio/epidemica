import 'package:flutter/material.dart';

import 'instrument.dart';
import 'response.dart';

/// Presents one instrument and returns the response, or null if the participant backed out.
///
/// Everything is on one scrollable page rather than one question per screen. A participant can see
/// how much is left before starting, which is what stops an instrument being abandoned halfway on
/// the assumption that it goes on for ever.
class SurveyScreen extends StatefulWidget {
  const SurveyScreen({required this.instrument, required this.response, super.key});

  final Instrument instrument;
  final SurveyResponse response;

  @override
  State<SurveyScreen> createState() => _SurveyScreenState();
}

class _SurveyScreenState extends State<SurveyScreen> {
  @override
  Widget build(BuildContext context) {
    final items = widget.instrument.items;
    final unanswered = items
        .where(
          (i) => i.required && widget.response.answerFor(i.id)?.status != AnswerStatus.answered,
        )
        .length;

    return Scaffold(
      appBar: AppBar(title: Text(widget.instrument.title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          if (widget.instrument.description != null) ...[
            Text(widget.instrument.description!, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 20),
          ],
          for (final item in items)
            _Item(item: item, response: widget.response, onChanged: _redraw),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: unanswered > 0 ? null : () => Navigator.pop(context, widget.response),
            child: Text(unanswered > 0 ? '$unanswered still to answer' : 'Send my answers'),
          ),
          const SizedBox(height: 8),
          TextButton(
            // Leaving part way through is recorded rather than discarded: attrition within an
            // instrument is a measurement, and one the study cannot recover afterwards.
            onPressed: () => Navigator.pop(context, widget.response),
            child: const Text('Finish later — send what I have'),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Not now')),
        ],
      ),
    );
  }

  void _redraw() => setState(() {});
}

class _Item extends StatelessWidget {
  const _Item({required this.item, required this.response, required this.onChanged});

  final InstrumentItem item;
  final SurveyResponse response;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.prompt, style: theme.textTheme.titleMedium),
          if (item.help != null) ...[
            const SizedBox(height: 4),
            Text(item.help!, style: theme.textTheme.bodySmall),
          ],
          const SizedBox(height: 8),
          switch (item.type) {
            ItemType.singleChoice => _SingleChoice(
              item: item,
              response: response,
              onChanged: onChanged,
            ),
            ItemType.multiChoice => _MultiChoice(
              item: item,
              response: response,
              onChanged: onChanged,
            ),
            ItemType.likert => _Likert(item: item, response: response, onChanged: onChanged),
          },
          if (!item.required)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                // Declining and never reaching an item are different measurements, so the screen
                // offers a way to say so rather than leaving silence to mean both.
                onPressed: () {
                  response.record(item.id, AnswerStatus.refused);
                  onChanged();
                },
                child: Text(
                  response.answerFor(item.id)?.status == AnswerStatus.refused
                      ? 'Declined'
                      : 'Rather not say',
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SingleChoice extends StatelessWidget {
  const _SingleChoice({required this.item, required this.response, required this.onChanged});

  final InstrumentItem item;
  final SurveyResponse response;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final answer = response.answerFor(item.id);
    final selected = answer?.status == AnswerStatus.answered ? answer!.value : null;

    return RadioGroup<Object>(
      groupValue: selected,
      onChanged: (value) {
        if (value == null) return;
        response.record(item.id, AnswerStatus.answered, value: value);
        onChanged();
      },
      child: Column(
        children: [
          for (final option in item.options)
            RadioListTile<Object>(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: option.value,
              title: Text(option.label),
            ),
        ],
      ),
    );
  }
}

class _MultiChoice extends StatelessWidget {
  const _MultiChoice({required this.item, required this.response, required this.onChanged});

  final InstrumentItem item;
  final SurveyResponse response;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final answer = response.answerFor(item.id);
    final chosen = answer?.status == AnswerStatus.answered && answer!.value is List
        ? List<Object>.from(answer.value! as List)
        : <Object>[];

    return Column(
      children: [
        for (final option in item.options)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: chosen.contains(option.value),
            title: Text(option.label),
            onChanged: (on) {
              final next = [...chosen];
              if (on == true) {
                next.add(option.value);
              } else {
                next.remove(option.value);
              }
              response.record(item.id, AnswerStatus.answered, value: next);
              onChanged();
            },
          ),
      ],
    );
  }
}

class _Likert extends StatelessWidget {
  const _Likert({required this.item, required this.response, required this.onChanged});

  final InstrumentItem item;
  final SurveyResponse response;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final scale = item.scale!;
    final answer = response.answerFor(item.id);
    final selected = answer?.status == AnswerStatus.answered ? answer!.value : null;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          children: [
            for (final value in scale.values)
              ChoiceChip(
                label: Text('$value'),
                selected: selected == value,
                onSelected: (_) {
                  response.record(item.id, AnswerStatus.answered, value: value);
                  onChanged();
                },
              ),
          ],
        ),
        if (scale.minLabel != null || scale.maxLabel != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(scale.minLabel ?? '', style: theme.textTheme.bodySmall),
                Text(scale.maxLabel ?? '', style: theme.textTheme.bodySmall),
              ],
            ),
          ),
      ],
    );
  }
}
