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
    required this.cancel,
    required this.cancelled,
    required this.unavailable,
    required this.invalidResponse,
  });

  static const en = CookingAssistantStrings(
    previous: 'Previous step',
    next: 'Next step',
    step: 'Step',
    stale: 'Account or session changed. Reopen this cooking session.',
    cancel: 'End cooking session',
    cancelled: 'This cooking session has ended.',
    unavailable: 'The cooking session could not be updated. Try again.',
    invalidResponse: 'The server response was rejected. Reopen the session.',
  );
  static const tr = CookingAssistantStrings(
    previous: 'Önceki adım',
    next: 'Sonraki adım',
    step: 'Adım',
    stale: 'Hesap veya oturum değişti. Bu pişirme oturumunu yeniden açın.',
    cancel: 'Pişirme oturumunu bitir',
    cancelled: 'Bu pişirme oturumu sona erdi.',
    unavailable: 'Pişirme oturumu güncellenemedi. Yeniden deneyin.',
    invalidResponse: 'Sunucu yanıtı reddedildi. Oturumu yeniden açın.',
  );

  final String previous;
  final String next;
  final String step;
  final String stale;
  final String cancel;
  final String cancelled;
  final String unavailable;
  final String invalidResponse;
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final session = controller.value;
    final strings = widget.strings;
    final canPrevious =
        !controller.busy && !session.cancelled && session.currentStep > 0;
    final canNext =
        !controller.busy &&
        !session.cancelled &&
        session.currentStep + 1 < session.steps.length;
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
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value:
                              (session.currentStep + 1) / session.steps.length,
                          semanticsLabel: strings.stepProgress(
                            session.currentStep + 1,
                            session.steps.length,
                          ),
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
                        if (session.cancelled) ...[
                          const SizedBox(height: 16),
                          Text(
                            strings.cancelled,
                            key: const Key('cooking-cancelled'),
                          ),
                        ] else if (controller.failure case final failure?) ...[
                          const SizedBox(height: 16),
                          Text(
                            switch (failure) {
                              CookingSessionFailure.staleAuthority =>
                                strings.stale,
                              CookingSessionFailure.unavailable =>
                                strings.unavailable,
                              CookingSessionFailure.invalidResponse =>
                                strings.invalidResponse,
                            },
                            key: const Key('cooking-failure'),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
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
                  constraints: BoxConstraints(
                    minWidth: horizontal ? 280 : 0,
                    maxWidth: horizontal ? 360 : constraints.maxWidth - 48,
                  ),
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
                          width: horizontal ? 360 : constraints.maxWidth - 48,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 48),
                            child: FilledButton.tonal(
                              key: const Key('cooking-previous'),
                              onPressed: canPrevious
                                  ? controller.previous
                                  : null,
                              child: Text(strings.previous),
                            ),
                          ),
                        ),
                      ),
                      Semantics(
                        button: true,
                        label: strings.cancel,
                        excludeSemantics: true,
                        child: SizedBox(
                          width: horizontal ? 360 : constraints.maxWidth - 48,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 48),
                            child: OutlinedButton.icon(
                              key: const Key('cooking-cancel'),
                              onPressed: controller.busy || session.cancelled
                                  ? null
                                  : controller.cancel,
                              icon: const Icon(Icons.stop_circle_outlined),
                              label: Text(strings.cancel),
                            ),
                          ),
                        ),
                      ),
                      Semantics(
                        button: true,
                        label: strings.next,
                        excludeSemantics: true,
                        child: SizedBox(
                          width: horizontal ? 360 : constraints.maxWidth - 48,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 48),
                            child: FilledButton(
                              key: const Key('cooking-next'),
                              onPressed: canNext ? controller.next : null,
                              child: Text(strings.next),
                            ),
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
