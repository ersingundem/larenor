import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/cooking_session_controller.dart';

@immutable
final class CookingAssistantStrings {
  const CookingAssistantStrings({
    required this.previous,
    required this.next,
    required this.step,
    required this.stale,
  });

  static const en = CookingAssistantStrings(
    previous: 'Previous step',
    next: 'Next step',
    step: 'Step',
    stale: 'Account or session changed. Reopen this cooking session.',
  );
  static const tr = CookingAssistantStrings(
    previous: 'Önceki adım',
    next: 'Sonraki adım',
    step: 'Adım',
    stale: 'Hesap veya oturum değişti. Bu pişirme oturumunu yeniden açın.',
  );

  final String previous;
  final String next;
  final String step;
  final String stale;
  String stepProgress(int current, int total) => '$step $current / $total';
}

final class _PreviousIntent extends Intent {
  const _PreviousIntent();
}

final class _NextIntent extends Intent {
  const _NextIntent();
}

class CookingSessionScreen extends StatefulWidget {
  const CookingSessionScreen({
    super.key,
    required this.controller,
    required this.strings,
  });
  final CookingSessionController controller;
  final CookingAssistantStrings strings;

  @override
  State<CookingSessionScreen> createState() => _CookingSessionScreenState();
}

class _CookingSessionScreenState extends State<CookingSessionScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant CookingSessionScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.controller.retire();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final session = controller.value;
    final strings = widget.strings;
    final canPrevious = !controller.busy && session.currentStep > 0;
    final canNext =
        !controller.busy && session.currentStep + 1 < session.steps.length;
    return FocusableActionDetector(
      autofocus: true,
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowLeft): _PreviousIntent(),
        SingleActivator(LogicalKeyboardKey.arrowRight): _NextIntent(),
      },
      actions: {
        _PreviousIntent: CallbackAction<_PreviousIntent>(
          onInvoke: (_) {
            if (canPrevious) controller.previous();
            return null;
          },
        ),
        _NextIntent: CallbackAction<_NextIntent>(
          onInvoke: (_) {
            if (canNext) controller.next();
            return null;
          },
        ),
      },
      child: Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final horizontal = constraints.maxWidth >= 900;
              final content = [
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    header: true,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          session.title,
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          strings.stepProgress(
                            session.currentStep + 1,
                            session.steps.length,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          session.steps[session.currentStep],
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        if (controller.failure ==
                            CookingSessionFailure.staleAuthority) ...[
                          const SizedBox(height: 16),
                          Text(strings.stale, key: const Key('cooking-stale')),
                        ],
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  width: horizontal ? 32 : 0,
                  height: horizontal ? 0 : 24,
                ),
                ConstrainedBox(
                  constraints: BoxConstraints(minWidth: horizontal ? 280 : 0),
                  child: Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    alignment: WrapAlignment.center,
                    children: [
                      Semantics(
                        button: true,
                        label: strings.previous,
                        excludeSemantics: true,
                        child: SizedBox(
                          height: 48,
                          child: FilledButton.tonal(
                            key: const Key('cooking-previous'),
                            onPressed: canPrevious ? controller.previous : null,
                            child: Text(strings.previous),
                          ),
                        ),
                      ),
                      Semantics(
                        button: true,
                        label: strings.next,
                        excludeSemantics: true,
                        child: SizedBox(
                          height: 48,
                          child: FilledButton(
                            key: const Key('cooking-next'),
                            onPressed: canNext ? controller.next : null,
                            child: Text(strings.next),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ];
              return Padding(
                padding: const EdgeInsets.all(24),
                child: horizontal
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: content,
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: content,
                      ),
              );
            },
          ),
        ),
      ),
    );
  }
}
