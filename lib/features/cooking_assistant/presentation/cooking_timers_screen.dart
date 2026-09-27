import 'dart:async';

import 'package:flutter/material.dart';

import '../data/cooking_timers_controller.dart';
import '../domain/cooking_timer.dart';

@immutable
final class CookingTimerStrings {
  const CookingTimerStrings({
    required this.title,
    required this.acknowledge,
    required this.running,
    required this.finished,
    required this.empty,
    required this.label,
    required this.minutes,
    required this.start,
    required this.cancel,
    required this.invalidDuration,
    required this.limitReached,
  });
  static const en = CookingTimerStrings(
    title: 'Cooking timers',
    acknowledge: 'Acknowledge timer',
    running: 'Running',
    finished: 'Finished',
    empty: 'No cooking timers',
    label: 'Timer name',
    minutes: 'Minutes',
    start: 'Start timer',
    cancel: 'Cancel timer',
    invalidDuration: 'Enter 1–10080 minutes.',
    limitReached: 'Up to 8 timers can run at once.',
  );
  static const tr = CookingTimerStrings(
    title: 'Pişirme zamanlayıcıları',
    acknowledge: 'Zamanlayıcıyı onayla',
    running: 'Çalışıyor',
    finished: 'Bitti',
    empty: 'Pişirme zamanlayıcısı yok',
    label: 'Zamanlayıcı adı',
    minutes: 'Dakika',
    start: 'Zamanlayıcıyı başlat',
    cancel: 'Zamanlayıcıyı iptal et',
    invalidDuration: '1–10080 dakika girin.',
    limitReached: 'Aynı anda en fazla 8 zamanlayıcı çalışabilir.',
  );
  final String title;
  final String acknowledge;
  final String running;
  final String finished;
  final String empty;
  final String label;
  final String minutes;
  final String start;
  final String cancel;
  final String invalidDuration;
  final String limitReached;
}

class CookingTimersScreen extends StatefulWidget {
  const CookingTimersScreen({
    super.key,
    required this.controller,
    required this.strings,
  });
  final CookingTimersController controller;
  final CookingTimerStrings strings;

  @override
  State<CookingTimersScreen> createState() => _CookingTimersScreenState();
}

class _CookingTimersScreenState extends State<CookingTimersScreen>
    with WidgetsBindingObserver {
  final _label = TextEditingController();
  final _minutes = TextEditingController();
  Timer? _ticker;
  String? _inputError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_changed);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      if (widget.controller.timers.any(
        (timer) =>
            !timer.notified &&
            widget.controller.remaining(timer) == Duration.zero,
      )) {
        widget.controller.resume();
      }
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant CookingTimersScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) widget.controller.resume();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_changed);
    _ticker?.cancel();
    _label.dispose();
    _minutes.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final minutes = int.tryParse(_minutes.text.trim());
    if (_label.text.trim().isEmpty ||
        minutes == null ||
        minutes < 1 ||
        minutes > 10080) {
      setState(() => _inputError = widget.strings.invalidDuration);
      return;
    }
    if (widget.controller.timers.length >= widget.controller.maximumTimers) {
      setState(() => _inputError = widget.strings.limitReached);
      return;
    }
    final created = await widget.controller.start(
      label: _label.text,
      duration: Duration(minutes: minutes),
    );
    if (!mounted) return;
    setState(() {
      _inputError = created ? null : widget.strings.invalidDuration;
      if (created) {
        _label.clear();
        _minutes.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    final timers = widget.controller.timers;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 900 ? 2 : 1;
            return CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
                  sliver: SliverToBoxAdapter(
                    child: Text(
                      strings.title,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                  sliver: SliverToBoxAdapter(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            SizedBox(
                              width: 260,
                              child: TextField(
                                key: const Key('cooking-timer-label'),
                                controller: _label,
                                maxLength: 100,
                                decoration: InputDecoration(
                                  labelText: strings.label,
                                  counterText: '',
                                ),
                                onSubmitted: (_) => _start(),
                              ),
                            ),
                            SizedBox(
                              width: 150,
                              child: TextField(
                                key: const Key('cooking-timer-minutes'),
                                controller: _minutes,
                                keyboardType: TextInputType.number,
                                decoration: InputDecoration(
                                  labelText: strings.minutes,
                                ),
                                onSubmitted: (_) => _start(),
                              ),
                            ),
                            SizedBox(
                              height: 48,
                              child: FilledButton.icon(
                                key: const Key('cooking-timer-start'),
                                onPressed: widget.controller.busy
                                    ? null
                                    : _start,
                                icon: const Icon(Icons.timer_outlined),
                                label: Text(strings.start),
                              ),
                            ),
                            if (_inputError case final error?)
                              Text(
                                error,
                                key: const Key('cooking-timer-input-error'),
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (timers.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: Text(strings.empty)),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.all(24),
                    sliver: SliverGrid.builder(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: 16,
                        mainAxisSpacing: 16,
                        mainAxisExtent: 380,
                      ),
                      itemCount: timers.length,
                      itemBuilder: (context, index) => _TimerCard(
                        timer: timers[index],
                        controller: widget.controller,
                        strings: strings,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _TimerCard extends StatelessWidget {
  const _TimerCard({
    required this.timer,
    required this.controller,
    required this.strings,
  });
  final CookingTimer timer;
  final CookingTimersController controller;
  final CookingTimerStrings strings;

  @override
  Widget build(BuildContext context) {
    final remaining = controller.remaining(timer);
    final finished = remaining == Duration.zero;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(timer.label, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Text(finished ? strings.finished : strings.running),
            const SizedBox(height: 8),
            Semantics(
              liveRegion: finished,
              value: _duration(remaining),
              child: Text(
                _duration(remaining),
                key: ValueKey('timer-remaining-${timer.id}'),
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
            const Spacer(),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                Semantics(
                  container: true,
                  button: true,
                  enabled: finished && !timer.acknowledged,
                  label: strings.acknowledge,
                  excludeSemantics: true,
                  child: SizedBox(
                    height: 48,
                    child: FilledButton(
                      key: const Key('timer-acknowledge'),
                      onPressed: finished && !timer.acknowledged
                          ? () => controller.acknowledge(timer.id)
                          : null,
                      child: Text(strings.acknowledge),
                    ),
                  ),
                ),
                SizedBox(
                  height: 48,
                  child: OutlinedButton.icon(
                    key: ValueKey('timer-cancel-${timer.id}'),
                    onPressed: controller.busy
                        ? null
                        : () => controller.cancel(timer.id),
                    icon: const Icon(Icons.close),
                    label: Text(strings.cancel),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _duration(Duration value) {
    final seconds = value.inSeconds.clamp(0, 7 * 24 * 60 * 60);
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final remainder = seconds % 60;
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${remainder.toString().padLeft(2, '0')}';
  }
}
