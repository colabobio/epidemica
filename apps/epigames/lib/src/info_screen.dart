import 'package:flutter/material.dart';

/// What the participant is told, before they agree and whenever they ask again.
///
/// The disclosure of simulated participants is the part that matters most. A player who believes
/// every infection came from a real person has been misled about what they are taking part in, and
/// no amount of correctness elsewhere repairs that.
class InfoScreen extends StatelessWidget {
  const InfoScreen({this.asConsent = false, super.key});

  final bool asConsent;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(asConsent ? 'Before you join' : 'How this works')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: const [
          _Section('The game', [
            'The game lasts seven days. Each day you either stay healthy or you are infected, and '
                'each morning you are told what happened overnight.',
            'Staying healthy earns you 2 points a day. While you are infected you earn nothing.',
            'Spending time near another player earns you both 5 points, once a day per person.',
          ]),
          _Section('Protection', [
            'You can protect yourself at any time. It stops you catching the infection and stops '
                'you passing it on, and it costs 1 point a day.',
            'While you are protected, time spent near other players earns nobody points. That is '
                'the choice the study is about: safety costs you something.',
          ]),
          _Section('Some of the other players are simulated', [
            'A group this size would rarely produce an outbreak on its own, so the game fills the '
                'rest of the population with simulated people.',
            'They can infect you and you can infect them. They are not real participants, they '
                'carry no data about anybody, and nobody is pretending otherwise — which is why '
                'this screen exists.',
          ]),
          _Section('If your phone stops sensing', [
            'If your phone stops recording — Bluetooth off, the app closed by the system, the '
                'battery flat — the study cannot see your day.',
            'You are treated as protected for that time, because we will not guess that you met '
                'nobody. You are not charged the protection point, but you do not earn for that '
                'day either. We only score days we can actually see.',
          ]),
          _Section('Leave the app running', [
            'The study needs the app to upload what it records. It does this on its own while it '
                'is running, including in the background.',
            'If you force-quit the app — swiping it away — it stops doing that until you open it '
                'again, and your day may be scored as if you were not there.',
          ]),
          _Section('What is recorded', [
            'A random code for each nearby participant, how close they were, and for how long.',
            'Your location is never recorded. Neither is anything about who you are.',
            'You can leave at any time. Everything held on this phone is deleted, including '
                'anything not yet uploaded.',
          ]),
        ],
      ),
      bottomNavigationBar: asConsent
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('No thanks'),
                      ),
                    ),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('I agree, join'),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.paragraphs);

  final String title;
  final List<String> paragraphs;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final paragraph in paragraphs)
            Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(paragraph)),
        ],
      ),
    );
  }
}
