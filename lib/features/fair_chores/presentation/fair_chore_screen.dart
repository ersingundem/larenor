import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../data/fair_chore_controller.dart';
import '../domain/fair_chore_models.dart';

class FairChoreStrings {
  const FairChoreStrings({
    required this.title,
    required this.loading,
    required this.empty,
    required this.offline,
    required this.error,
    required this.uncertain,
    required this.assignee,
    required this.due,
    required this.complete,
    required this.defer,
    required this.reconcile,
  });

  static const en = FairChoreStrings(
    title: 'Household chores',
    loading: 'Loading current chores',
    empty: 'No chores are assigned',
    offline: 'Core is not reachable',
    error: 'Current chore state could not be verified',
    uncertain: 'The result is uncertain. Read the receipt before trying again.',
    assignee: 'Assigned to',
    due: 'Due',
    complete: 'Complete',
    defer: 'Defer one day',
    reconcile: 'Check result',
  );

  static const tr = FairChoreStrings(
    title: 'Ev işleri',
    loading: 'Güncel ev işleri yükleniyor',
    empty: 'Atanmış ev işi yok',
    offline: 'Core erişilebilir değil',
    error: 'Güncel ev işi durumu doğrulanamadı',
    uncertain: 'Sonuç belirsiz. Yeniden denemeden önce makbuzu okuyun.',
    assignee: 'Atanan kişi',
    due: 'Son tarih',
    complete: 'Tamamla',
    defer: 'Bir gün ertele',
    reconcile: 'Sonucu denetle',
  );

  final String title;
  final String loading;
  final String empty;
  final String offline;
  final String error;
  final String uncertain;
  final String assignee;
  final String due;
  final String complete;
  final String defer;
  final String reconcile;
}

class FairChoreScreen extends StatefulWidget {
  const FairChoreScreen({
    super.key,
    required this.controller,
    required this.authority,
    required this.strings,
  });

  final FairChoreController controller;
  final FairChoreAuthority authority;
  final FairChoreStrings strings;

  @override
  State<FairChoreScreen> createState() => _FairChoreScreenState();
}

class _FairChoreScreenState extends State<FairChoreScreen> {
  late FairChoreLease _lease;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    _lease = widget.controller.bind(widget.authority);
    widget.controller.addListener(_changed);
    widget.controller.load(_lease);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant FairChoreScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.authority != widget.authority) {
      oldWidget.controller.removeListener(_changed);
      oldWidget.controller.detach(_lease);
      _attach();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.controller.detach(_lease);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(strings.title)),
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final horizontal = constraints.maxWidth >= 900 ? 32.0 : 16.0;
            final cardWidth = constraints.maxWidth >= 900
                ? (constraints.maxWidth - horizontal * 2 - 16) / 2
                : constraints.maxWidth - horizontal * 2;
            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(horizontal, 24, horizontal, 32),
              child: _body(strings, cardWidth),
            );
          },
        ),
      ),
    );
  }

  Widget _body(FairChoreStrings strings, double cardWidth) {
    switch (widget.controller.state) {
      case FairChoreViewState.detached ||
          FairChoreViewState.idle ||
          FairChoreViewState.loading:
        return _Status(strings.loading, const CupertinoActivityIndicator());
      case FairChoreViewState.empty:
        return _Status(
          strings.empty,
          const Icon(CupertinoIcons.check_mark_circled),
        );
      case FairChoreViewState.offline:
        return _Status(strings.offline, const Icon(CupertinoIcons.wifi_slash));
      case FairChoreViewState.error:
        return _Status(
          strings.error,
          const Icon(CupertinoIcons.exclamationmark_triangle),
        );
      case FairChoreViewState.uncertain:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Status(strings.uncertain, const Icon(CupertinoIcons.clock)),
            const SizedBox(height: 16),
            _ActionButton(
              key: const ValueKey('chore-reconcile'),
              label: strings.reconcile,
              semanticLabel: strings.reconcile,
              onPressed: () => widget.controller.reconcile(_lease),
            ),
          ],
        );
      case FairChoreViewState.ready || FairChoreViewState.busy:
        return Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            for (var index = 0; index < widget.controller.tasks.length; index++)
              SizedBox(
                width: cardWidth,
                child: _taskCard(
                  strings,
                  widget.controller.tasks[index],
                  autofocus: index == 0,
                ),
              ),
          ],
        );
    }
  }

  Widget _taskCard(
    FairChoreStrings strings,
    FairChoreTask task, {
    required bool autofocus,
  }) {
    final enabled = widget.controller.state == FairChoreViewState.ready;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              task.title,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text('${strings.assignee}: ${task.assigneeId}'),
            Text(
              '${strings.due}: ${task.dueAt.toLocal().toIso8601String().substring(0, 16)}',
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _ActionButton(
                  key: ValueKey('chore-complete-${task.id}'),
                  label: strings.complete,
                  semanticLabel: '${strings.complete} ${task.title}',
                  autofocus: autofocus,
                  onPressed: enabled
                      ? () => widget.controller.complete(_lease, task)
                      : null,
                ),
                _ActionButton(
                  key: ValueKey('chore-defer-${task.id}'),
                  label: strings.defer,
                  semanticLabel: '${strings.defer} ${task.title}',
                  onPressed: enabled
                      ? () => widget.controller.defer(_lease, task, days: 1)
                      : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Status extends StatelessWidget {
  const _Status(this.label, this.icon);

  final String label;
  final Widget icon;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    label: label,
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Row(
        children: [
          icon,
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
        ],
      ),
    ),
  );
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    super.key,
    required this.label,
    required this.semanticLabel,
    required this.onPressed,
    this.autofocus = false,
  });

  final String label;
  final String semanticLabel;
  final VoidCallback? onPressed;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onPressed != null,
    label: semanticLabel,
    onTap: onPressed,
    excludeSemantics: true,
    child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): () =>
            onPressed?.call(),
        const SingleActivator(LogicalKeyboardKey.space): () =>
            onPressed?.call(),
      },
      child: Focus(
        autofocus: autofocus,
        child: SizedBox(
          height: 48,
          child: CupertinoButton.filled(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            onPressed: onPressed,
            child: Text(label),
          ),
        ),
      ),
    ),
  );
}
