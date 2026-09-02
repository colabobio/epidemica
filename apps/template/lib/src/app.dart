import 'dart:async';

import 'package:flutter/material.dart';

import 'permissions.dart';
import 'study_controller.dart';

class EpidemicaApp extends StatelessWidget {
  const EpidemicaApp({required this.controller, super.key});

  final StudyController controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Epidemica',
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
    home: HomeScreen(controller: controller),
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({required this.controller, super.key});

  final StudyController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Timer? _sync;

  @override
  void initState() {
    super.initState();
    // Foreground sync only. Background scheduling is deliberately not wired yet: the outbox
    // already guarantees nothing is lost while offline, so this is about promptness, not safety.
    _sync = Timer.periodic(const Duration(minutes: 5), (_) => widget.controller.sync());
  }

  @override
  void dispose() {
    _sync?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      return Scaffold(
        appBar: AppBar(title: const Text('Epidemica')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: switch (controller.state) {
            StudyState.notEnrolled || StudyState.refused => _JoinView(controller: controller),
            StudyState.enrolled || StudyState.collecting => _StatusView(controller: controller),
          },
        ),
      );
    },
  );
}

class _JoinView extends StatefulWidget {
  const _JoinView({required this.controller});

  final StudyController controller;

  @override
  State<_JoinView> createState() => _JoinViewState();
}

class _JoinViewState extends State<_JoinView> {
  final _code = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    setState(() => _busy = true);
    await Permissions.requestForProximity();
    await widget.controller.join(_code.text);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('Join a study', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 8),
      const Text('Enter the code you were given.'),
      const SizedBox(height: 24),
      TextField(
        controller: _code,
        autocorrect: false,
        textCapitalization: TextCapitalization.characters,
        decoration: const InputDecoration(labelText: 'Study code', border: OutlineInputBorder()),
      ),
      const SizedBox(height: 16),
      FilledButton(onPressed: _busy ? null : _join, child: const Text('Join')),
      if (widget.controller.message != null) ...[
        const SizedBox(height: 24),
        _Notice(text: widget.controller.message!),
      ],
    ],
  );
}

class _StatusView extends StatelessWidget {
  const _StatusView({required this.controller});

  final StudyController controller;

  @override
  Widget build(BuildContext context) {
    final enrollment = controller.enrollment;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(enrollment?.bundle.title ?? 'Enrolled',
            style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 24),
        _Row(
          label: 'Recording',
          value: controller.state == StudyState.collecting
              ? controller.runningModules.join(', ')
              : 'not started',
        ),
        _Row(label: 'Waiting to send', value: '${controller.pendingObservations}'),
        _Row(
          label: 'Last sent',
          value: controller.lastSyncAt == null
              ? 'never'
              : controller.lastSyncAt!.toLocal().toString().split('.').first,
        ),
        // Shown because a participant is entitled to know the study is not silently discarding
        // their data, and because a non-zero value here is a bug worth reporting.
        if (controller.deadLetterCount > 0)
          _Row(label: 'Could not be sent', value: '${controller.deadLetterCount}'),
        const Spacer(),
        if (controller.message != null) _Notice(text: controller.message!),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: () => _confirmWithdraw(context),
          child: const Text('Leave this study'),
        ),
      ],
    );
  }

  Future<void> _confirmWithdraw(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave this study?'),
        content: const Text(
          'Recording stops and everything held on this phone is deleted, including anything '
          'not yet sent. Observations already sent are held by the study.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Leave')),
        ],
      ),
    );
    if (confirmed ?? false) await controller.withdraw();
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
        Text(value, style: Theme.of(context).textTheme.bodyMedium),
      ],
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
  );
}
