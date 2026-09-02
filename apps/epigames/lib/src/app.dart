import 'dart:async';

import 'package:epidemica_core/epidemica_core.dart';
import 'package:epidemica_proximity_module/epidemica_proximity_module.dart';
import 'package:flutter/material.dart';

import 'game_state.dart';
import 'info_screen.dart';

/// The whole app.
///
/// It renders a state document and posts decisions. Nothing here decides what happened to a
/// participant: that is the twin's job, and duplicating any of it would give the player one answer
/// and the study another.
class EpigamesApp extends StatelessWidget {
  const EpigamesApp({required this.controller, super.key});

  final StudyController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Epigame',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, fontFamily: 'Roboto'),
      home: _Home(controller: controller),
    );
  }
}

class _Home extends StatefulWidget {
  const _Home({required this.controller});

  final StudyController controller;

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  final TextEditingController _code = TextEditingController();
  Timer? _poll;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
    // The game moves once a day, so polling is generous at a minute. What it protects against is a
    // participant staring at yesterday's screen because nothing prompted a refresh.
    _poll = Timer.periodic(const Duration(minutes: 1), (_) => _refresh());
    _refresh();
  }

  @override
  void dispose() {
    _poll?.cancel();
    widget.controller.removeListener(_onChange);
    _code.dispose();
    super.dispose();
  }

  void _onChange() => setState(() {});

  Future<void> _refresh() async {
    if (widget.controller.state == StudyState.notEnrolled) return;
    await widget.controller.sync();
    await widget.controller.refreshState();
  }

  Future<void> _act(String action) async {
    setState(() => _busy = true);
    await widget.controller.postAction({'action': action});
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.controller.state == StudyState.notEnrolled ||
        widget.controller.state == StudyState.refused) {
      return _JoinScreen(controller: widget.controller, code: _code);
    }

    final game = GameState.from(widget.controller.participantState);
    final startsAt = widget.controller.enrollment?.bundle.startsAt;

    // Joining before the study opens is normal — codes go out in advance — so the app says when
    // play starts rather than leaving a participant to wonder whether something is broken.
    if (!game.hasState && startsAt != null && DateTime.now().toUtc().isBefore(startsAt)) {
      return _WaitingScreen(
        startsAt: startsAt,
        onLeave: () async {
          final confirmed = await _confirmLeave(context);
          if (confirmed) await widget.controller.withdraw();
        },
      );
    }

    return _GameScreen(
      game: game,
      busy: _busy,
      pending: widget.controller.pendingObservations,
      onProtect: () => _act(game.protected ? 'release' : 'protect'),
      onRefresh: _refresh,
      onLeave: () async {
        final confirmed = await _confirmLeave(context);
        if (confirmed) await widget.controller.withdraw();
      },
    );
  }
}

/// Shown to a participant who joined before the study opens.
class _WaitingScreen extends StatelessWidget {
  const _WaitingScreen({required this.startsAt, required this.onLeave});

  final DateTime startsAt;
  final Future<void> Function() onLeave;

  @override
  Widget build(BuildContext context) {
    final until = startsAt.difference(DateTime.now().toUtc());
    final when = until.inHours >= 24
        ? 'in ${until.inDays + 1} days'
        : until.inHours >= 1
        ? 'in ${until.inHours} hours'
        : 'in ${until.inMinutes} minutes';

    return Scaffold(
      backgroundColor: const Color(0xFF37474F),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.hourglass_empty, size: 56, color: Colors.white70),
              const SizedBox(height: 24),
              const Text(
                "You're in.",
                style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w300),
              ),
              const SizedBox(height: 8),
              Text(
                'The game starts $when.',
                style: const TextStyle(color: Colors.white, fontSize: 18),
              ),
              const SizedBox(height: 16),
              const Text(
                'Your phone is already recording who you spend time near, so leave the app '
                'installed. Nothing counts towards your score until the game begins.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 32),
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const InfoScreen()),
                ),
                child: const Text('How this works', style: TextStyle(color: Colors.white)),
              ),
              TextButton(
                onPressed: onLeave,
                child: const Text('Leave the study', style: TextStyle(color: Colors.white54)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<bool> _confirmLeave(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Leave the study?'),
      content: const Text(
        'Collection stops and everything held on this phone is deleted, including anything not '
        'yet uploaded. You cannot rejoin with the same identity.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Stay')),
        TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Leave')),
      ],
    ),
  );
  return result ?? false;
}

/// The one screen a player normally sees: a colour, a number, and two decisions.
class _GameScreen extends StatelessWidget {
  const _GameScreen({
    required this.game,
    required this.busy,
    required this.pending,
    required this.onProtect,
    required this.onRefresh,
    required this.onLeave,
  });

  final GameState game;
  final bool busy;
  final int pending;
  final VoidCallback onProtect;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onLeave;

  @override
  Widget build(BuildContext context) {
    final onColour = game.colour.computeLuminance() > 0.4 ? Colors.black : Colors.white;

    return Scaffold(
      backgroundColor: game.colour,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: onRefresh,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            children: [
              _TopBar(game: game, onColour: onColour),
              const SizedBox(height: 48),
              Center(
                child: Column(
                  children: [
                    if (game.finished)
                      Text(
                        'GAME OVER',
                        style: TextStyle(
                          color: onColour.withValues(alpha: 0.9),
                          letterSpacing: 4,
                          fontSize: 18,
                        ),
                      ),
                    if (game.protected && !game.finished)
                      Icon(Icons.shield, size: 64, color: onColour.withValues(alpha: 0.9)),
                    if (game.protected && !game.finished) const SizedBox(height: 8),
                    Text(
                      game.finished ? 'FINAL SCORE' : 'POINTS',
                      style: TextStyle(
                        color: onColour.withValues(alpha: 0.7),
                        letterSpacing: 6,
                        fontSize: 16,
                      ),
                    ),
                    Text(
                      '${game.points}',
                      style: TextStyle(
                        color: onColour,
                        fontSize: 96,
                        fontWeight: FontWeight.w200,
                        height: 1.1,
                      ),
                    ),
                    Text(
                      game.finished ? 'You finished ${game.stateLabel.toLowerCase()}' : game.stateLabel,
                      style: TextStyle(color: onColour, fontSize: 22, letterSpacing: 1),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              if (game.settlement != null) _SettlementCard(game: game, onColour: onColour),
              const SizedBox(height: 16),
              _Aggregate(game: game, onColour: onColour),
              const SizedBox(height: 32),
              // The decision disappears when there is no longer a day it could apply to. Leaving a
              // live button on a finished game invites a participant to spend a point on nothing.
              if (game.hasState && !game.finished)
                FilledButton.tonal(
                  onPressed: busy || game.protectionForced ? null : onProtect,
                  child: Text(
                    game.protectionForced
                        ? 'Protected because your phone is not sensing'
                        : game.protected
                        ? 'Stop protecting'
                        : 'Protect me',
                  ),
                ),
              if (game.finished)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Thank you for taking part. You can leave the study now; your phone has '
                      'stopped recording.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: onColour.withValues(alpha: 0.85)),
                    ),
                  ),
                ),
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const InfoScreen()),
                ),
                child: Text('How this works', style: TextStyle(color: onColour)),
              ),
              TextButton(
                onPressed: onLeave,
                child: Text(
                  'Leave the study',
                  style: TextStyle(color: onColour.withValues(alpha: 0.7)),
                ),
              ),
              if (pending > 0)
                Center(
                  child: Text(
                    '$pending observations waiting to upload',
                    style: TextStyle(color: onColour.withValues(alpha: 0.6), fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.game, required this.onColour});

  final GameState game;
  final Color onColour;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(game.dayLabel, style: TextStyle(color: onColour, fontSize: 16)),
        // Staleness is stated rather than implied. The screen is a daily computation, and an
        // interface that looks live claims a freshness it does not have.
        Text(
          game.freshness,
          style: TextStyle(color: onColour.withValues(alpha: 0.7), fontSize: 13),
        ),
      ],
    );
  }
}

class _SettlementCard extends StatelessWidget {
  const _SettlementCard({required this.game, required this.onColour});

  final GameState game;
  final Color onColour;

  @override
  Widget build(BuildContext context) {
    final settlement = game.settlement!;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: onColour.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Day ${settlement.day}',
            style: TextStyle(color: onColour, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          _Line(label: 'Brought forward', value: settlement.opening, onColour: onColour),
          for (final line in settlement.lines)
            _Line(
              label: GameState.describe(line),
              value: line.points,
              signed: true,
              onColour: onColour,
            ),
          Divider(color: onColour.withValues(alpha: 0.2)),
          _Line(
            label: 'Total',
            value: settlement.closing,
            bold: true,
            onColour: onColour,
          ),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({
    required this.label,
    required this.value,
    required this.onColour,
    this.signed = false,
    this.bold = false,
  });

  final String label;
  final int value;
  final Color onColour;
  final bool signed;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: onColour,
      fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(child: Text(label, style: style)),
          Text(signed && value >= 0 ? '+$value' : '$value', style: style),
        ],
      ),
    );
  }
}

class _Aggregate extends StatelessWidget {
  const _Aggregate({required this.game, required this.onColour});

  final GameState game;
  final Color onColour;

  @override
  Widget build(BuildContext context) {
    if (!game.hasState) return const SizedBox.shrink();

    return Center(
      child: Text(
        '${game.totalCases} of ${game.population} have been infected so far',
        style: TextStyle(color: onColour.withValues(alpha: 0.8)),
      ),
    );
  }
}

class _JoinScreen extends StatelessWidget {
  const _JoinScreen({required this.controller, required this.code});

  final StudyController controller;
  final TextEditingController code;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('Epigame', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w300)),
              const SizedBox(height: 8),
              const Text('Seven days. Stay healthy, or protect yourself and pay for it.'),
              const SizedBox(height: 32),
              TextField(
                controller: code,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Join code',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () async {
                  // Consent before enrolment, and before any permission prompt: a participant
                  // cannot agree to a study whose rules they have not been shown.
                  final agreed = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(builder: (_) => const InfoScreen(asConsent: true)),
                  );
                  if (agreed != true) return;
                  await Permissions.requestForProximity();
                  await controller.join(code.text);
                },
                child: const Text('Read the rules and join'),
              ),
              if (controller.message != null) ...[
                const SizedBox(height: 24),
                Text(controller.message!, style: const TextStyle(color: Colors.redAccent)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
