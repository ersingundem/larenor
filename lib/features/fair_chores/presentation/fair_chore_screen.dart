import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../../l10n/generated/app_localizations.dart';
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

  factory FairChoreStrings.fromLocalizations(AppLocalizations value) =>
      FairChoreStrings(
        title: value.fairChoresTitle,
        loading: value.fairChoresLoading,
        empty: value.fairChoresEmpty,
        offline: value.fairChoresOffline,
        error: value.fairChoresError,
        uncertain: value.fairChoresUncertain,
        assignee: value.fairChoresAssignee,
        due: value.fairChoresDue,
        complete: value.fairChoresComplete,
        defer: value.fairChoresDefer,
        reconcile: value.fairChoresReconcile,
      );

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
    this.turkish = false,
  });

  final FairChoreController controller;
  final FairChoreAuthority authority;
  final FairChoreStrings strings;
  final bool turkish;

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
      navigationBar: CupertinoNavigationBar(
        middle: Text(strings.title),
        trailing: widget.authority.canManage
            ? CupertinoButton(
                key: const ValueKey('chore-create'),
                padding: EdgeInsets.zero,
                minimumSize: const Size.square(44),
                onPressed: widget.controller.state == FairChoreViewState.busy
                    ? null
                    : _showCreate,
                child: Semantics(
                  button: true,
                  label: _t('Add recurring chore', 'Tekrarlayan görev ekle'),
                  child: const Icon(CupertinoIcons.add),
                ),
              )
            : null,
      ),
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

  String _t(String english, String turkish) =>
      widget.turkish ? turkish : english;

  Future<void> _showCreate() async {
    if (!widget.authority.canManage ||
        widget.controller.state == FairChoreViewState.busy) {
      return;
    }
    final draft = await showCupertinoModalPopup<_FairChoreDraft>(
      context: context,
      builder: (context) => _CreateChoreSheet(turkish: widget.turkish),
    );
    if (!mounted || draft == null) return;
    await widget.controller.create(
      _lease,
      title: draft.title,
      timezone: draft.timezone,
      intervalDays: draft.intervalDays,
      dueAt: draft.dueAt,
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
        return _retryStatus(
          strings.offline,
          const Icon(CupertinoIcons.wifi_slash),
          strings.reconcile,
        );
      case FairChoreViewState.error:
        return _retryStatus(
          strings.error,
          const Icon(CupertinoIcons.exclamationmark_triangle),
          strings.reconcile,
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

  Widget _retryStatus(String label, Widget icon, String action) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Status(label, icon),
      const SizedBox(height: 16),
      _ActionButton(
        label: action,
        semanticLabel: action,
        onPressed: () => widget.controller.load(_lease),
      ),
    ],
  );

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
            Text(
              '${strings.assignee}: ${task.memberOrder.any((member) => member.id == task.assigneeId) ? task.assigneeLabel : _t('Former member', 'Ayrılmış üye')}',
            ),
            Text(
              '${strings.due}: ${task.dueAt.toLocal().toIso8601String().substring(0, 16)}',
            ),
            const SizedBox(height: 6),
            Text(
              _t(
                'Repeats every ${task.intervalDays} day(s) · ${task.timezone}',
                '${task.intervalDays} günde bir tekrarlanır · ${task.timezone}',
              ),
              style: const TextStyle(
                color: CupertinoColors.secondaryLabel,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _t('Rotation', 'Kişi sırası'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              task.memberOrder.map((member) => member.label).join('  →  '),
              style: const TextStyle(
                color: CupertinoColors.secondaryLabel,
                fontSize: 14,
              ),
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
                  onPressed: enabled && task.permissions.complete
                      ? () => widget.controller.complete(_lease, task)
                      : null,
                ),
                _ActionButton(
                  key: ValueKey('chore-defer-${task.id}'),
                  label: _t('Defer', 'Ertele'),
                  semanticLabel: '${strings.defer} ${task.title}',
                  filled: false,
                  onPressed: enabled && task.permissions.defer
                      ? () => _showDefer(task)
                      : null,
                ),
                _ActionButton(
                  key: ValueKey('chore-skip-${task.id}'),
                  label: _t('Pass to next person', 'Sıradaki kişiye geçir'),
                  semanticLabel: _t(
                    'Pass ${task.title} to the next person',
                    '${task.title} görevini sıradaki kişiye geçir',
                  ),
                  filled: false,
                  onPressed: enabled && task.permissions.skip
                      ? () => _confirmSkip(task)
                      : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showDefer(FairChoreTask task) async {
    final days = await showCupertinoModalPopup<int>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(_t('Defer ${task.title}', '${task.title} görevini ertele')),
        actions: [
          for (final days in const [1, 3, 7])
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(context).pop(days),
              child: Text(_t('$days day(s)', '$days gün')),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_t('Cancel', 'Vazgeç')),
        ),
      ),
    );
    if (!mounted || days == null) return;
    await widget.controller.defer(_lease, task, days: days);
  }

  Future<void> _confirmSkip(FairChoreTask task) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(_t('Pass this chore?', 'Görev devredilsin mi?')),
        content: Text(
          _t(
            'The due date stays the same and the next person in the rotation becomes responsible.',
            'Son tarih değişmez ve sıradaki kişi görevden sorumlu olur.',
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_t('Cancel', 'Vazgeç')),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_t('Pass', 'Devret')),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await widget.controller.skip(_lease, task);
  }
}

class _FairChoreDraft {
  const _FairChoreDraft({
    required this.title,
    required this.timezone,
    required this.intervalDays,
    required this.dueAt,
  });

  final String title;
  final String timezone;
  final int intervalDays;
  final DateTime dueAt;
}

class _CreateChoreSheet extends StatefulWidget {
  const _CreateChoreSheet({required this.turkish});

  final bool turkish;

  @override
  State<_CreateChoreSheet> createState() => _CreateChoreSheetState();
}

class _CreateChoreSheetState extends State<_CreateChoreSheet> {
  late final TextEditingController _title;
  late final TextEditingController _timezone;
  late DateTime _dueAt;
  int _intervalDays = 7;

  String _t(String english, String turkish) =>
      widget.turkish ? turkish : english;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController();
    _timezone = TextEditingController(
      text: widget.turkish ? 'Europe/Istanbul' : 'UTC',
    );
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    _dueAt = DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 9);
  }

  @override
  void dispose() {
    _title.dispose();
    _timezone.dispose();
    super.dispose();
  }

  bool get _valid =>
      _title.text.trim().isNotEmpty && _timezone.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Container(
      height: 590,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      decoration: const BoxDecoration(
        color: CupertinoColors.systemGroupedBackground,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 5,
              decoration: BoxDecoration(
                color: CupertinoColors.systemGrey3,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Text(
                  _t('New recurring chore', 'Yeni tekrarlayan görev'),
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                onPressed: () => Navigator.of(context).pop(),
                child: Text(_t('Cancel', 'Vazgeç')),
              ),
            ],
          ),
          const SizedBox(height: 12),
          CupertinoTextField(
            key: const ValueKey('chore-create-title'),
            controller: _title,
            autofocus: true,
            maxLength: 200,
            placeholder: _t('Chore title', 'Görev adı'),
            textInputAction: TextInputAction.next,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          CupertinoTextField(
            key: const ValueKey('chore-create-timezone'),
            controller: _timezone,
            maxLength: 128,
            placeholder: _t(
              'IANA timezone, for example UTC',
              'IANA saat dilimi',
            ),
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 18),
          Text(
            _t('Repeat interval', 'Tekrar aralığı'),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          CupertinoSlidingSegmentedControl<int>(
            groupValue: _intervalDays,
            children: {
              for (final days in const [1, 7, 14, 30])
                days: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(_t('$days d', '$days g')),
                ),
            },
            onValueChanged: (value) {
              if (value != null) setState(() => _intervalDays = value);
            },
          ),
          const SizedBox(height: 18),
          Text(
            _t('First due date', 'İlk son tarih'),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          Expanded(
            child: CupertinoDatePicker(
              key: const ValueKey('chore-create-due'),
              mode: CupertinoDatePickerMode.dateAndTime,
              initialDateTime: _dueAt,
              minimumDate: DateTime.now(),
              maximumDate: DateTime.now().add(const Duration(days: 365)),
              use24hFormat: true,
              onDateTimeChanged: (value) => _dueAt = value,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 50,
            child: CupertinoButton.filled(
              key: const ValueKey('chore-create-submit'),
              onPressed: !_valid
                  ? null
                  : () => Navigator.of(context).pop(
                      _FairChoreDraft(
                        title: _title.text.trim(),
                        timezone: _timezone.text.trim(),
                        intervalDays: _intervalDays,
                        dueAt: _dueAt,
                      ),
                    ),
              child: Text(_t('Create chore', 'Görevi oluştur')),
            ),
          ),
        ],
      ),
    ),
  );
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
    this.filled = true,
  });

  final String label;
  final String semanticLabel;
  final VoidCallback? onPressed;
  final bool autofocus;
  final bool filled;

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
          child: filled
              ? CupertinoButton.filled(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  onPressed: onPressed,
                  child: Text(label),
                )
              : CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  onPressed: onPressed,
                  child: Text(label),
                ),
        ),
      ),
    ),
  );
}
