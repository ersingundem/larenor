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
  });
  static const en = CookingTimerStrings(
    title: 'Cooking timers',
    acknowledge: 'Acknowledge timer',
    running: 'Running',
    finished: 'Finished',
    empty: 'No cooking timers',
  );
  static const tr = CookingTimerStrings(
    title: 'Pişirme zamanlayıcıları',
    acknowledge: 'Zamanlayıcıyı onayla',
    running: 'Çalışıyor',
    finished: 'Bitti',
    empty: 'Pişirme zamanlayıcısı yok',
  );
  final String title;
  final String acknowledge;
  final String running;
  final String finished;
  final String empty;
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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_changed);
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
    super.dispose();
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
                        mainAxisExtent: 210,
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
    final finished = controller.remaining(timer) == Duration.zero;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(timer.label, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Text(finished ? strings.finished : strings.running),
            const Spacer(),
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
          ],
        ),
      ),
    );
  }
}
