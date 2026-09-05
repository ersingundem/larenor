import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../media/hub/presentation/media_session_state.dart';
import '../domain/screen_program.dart';
import '../providers/screen_program_provider.dart';

String _time(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';
String _day(BuildContext context, int weekday) =>
    DateFormat.E(Localizations.localeOf(context).toString())
        .format(DateTime(2026, 1, 4 + weekday));
String _awake(AppLocalizations l10n, ScreenAwakeMode mode) => switch (mode) {
  ScreenAwakeMode.inherit => l10n.screenProgramInherit,
  ScreenAwakeMode.keepAwake => l10n.screenProgramKeepAwake,
  ScreenAwakeMode.systemTimeout => l10n.screenProgramSystemTimeout,
};

class ScreenProgramScreen extends ConsumerStatefulWidget {
  const ScreenProgramScreen({super.key});
  @override
  ConsumerState<ScreenProgramScreen> createState() =>
      _ScreenProgramScreenState();
}

class _ScreenProgramScreenState extends MediaSessionState<ScreenProgramScreen> {
  Route<dynamic>? _ownedRoute;
  bool _saving = false;
  String? _error;
  @override
  void clearPendingInteraction() {
    final route = _ownedRoute;
    _ownedRoute = null;
    if (route?.isActive == true) route!.navigator?.removeRoute(route);
  }

  bool _current(int epoch, {bool ownRoute = false}) =>
      sessionCurrent(epoch) &&
      (ModalRoute.of(context)?.isCurrent == true ||
          (ownRoute && _ownedRoute?.isCurrent == true));
  bool _same(ScreenProgram original, int epoch) {
    if (!_current(epoch)) return false;
    final reading = ref.read(screenProgramProvider);
    return !reading.isLoading &&
        !reading.hasError &&
        identical(reading.value, original);
  }

  Future<void> _save(
    ScreenProgram next,
    ScreenProgram original,
    int epoch,
  ) async {
    if (_saving || !_same(original, epoch)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(screenProgramProvider.notifier)
          .save(next, isCurrent: () => _same(original, epoch));
    } catch (_) {
      if (_current(epoch)) {
        setState(
          () => _error = AppLocalizations.of(context).screenProgramSaveFailed,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _edit(ScreenProgram program, [ScreenProgramRule? rule]) async {
    final epoch = sessionGeneration;
    if (_saving || !_same(program, epoch) || _ownedRoute != null) return;
    if (rule == null && program.rules.length >= ScreenProgram.maxRules) return;
    final route = CupertinoPageRoute<ScreenProgramRule>(
      builder: (_) => _ScreenRuleEditor(
        initial:
            rule ??
            ScreenProgramRule(
              id: 'rule-${DateTime.now().microsecondsSinceEpoch}',
              days: {1, 2, 3, 4, 5, 6, 7},
              startMinutes: 22 * 60,
              endMinutes: 7 * 60,
              dim: true,
            ),
        sourceCurrent: () => sessionCurrent(epoch),
      ),
    );
    _ownedRoute = route;
    final edited = await Navigator.of(context).push(route);
    if (identical(_ownedRoute, route)) _ownedRoute = null;
    if (edited == null || !_same(program, epoch)) return;
    final rules = List<ScreenProgramRule>.of(program.rules);
    if (rule == null) {
      rules.add(edited);
    } else {
      rules[rules.indexOf(rule)] = edited;
    }
    await _save(
      ScreenProgram(enabled: program.enabled, rules: rules),
      program,
      epoch,
    );
  }

  Future<void> _remove(ScreenProgram program, ScreenProgramRule rule) async {
    final epoch = sessionGeneration;
    if (_saving || !_same(program, epoch) || _ownedRoute != null) return;
    final l10n = AppLocalizations.of(context);
    final route = CupertinoDialogRoute<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(rule.name.isEmpty ? l10n.screenProgramRule : rule.name),
        content: Text(
          '${_time(rule.startMinutes)} – ${_time(rule.endMinutes)}',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => _close(dialogContext, false),
            child: Text(l10n.commonCancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => _close(dialogContext, true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    _ownedRoute = route;
    final confirmed = await Navigator.of(context).push(route);
    if (identical(_ownedRoute, route)) _ownedRoute = null;
    if (confirmed != true || !_same(program, epoch)) return;
    await _save(
      ScreenProgram(
        enabled: program.enabled,
        rules: program.rules.where((v) => v.id != rule.id).toList(),
      ),
      program,
      epoch,
    );
  }

  void _close<T>(BuildContext modal, T value) {
    if (mounted &&
        interactionActive &&
        modal.mounted &&
        ModalRoute.of(modal)?.isCurrent == true) {
      Navigator.pop(modal, value);
    }
  }

  void _move(ScreenProgram program, int index, int offset) {
    final epoch = sessionGeneration;
    if (_saving || !_same(program, epoch)) return;
    final next = index + offset;
    if (next < 0 || next >= program.rules.length) return;
    final rules = List<ScreenProgramRule>.of(program.rules);
    rules.insert(next, rules.removeAt(index));
    _save(
      ScreenProgram(enabled: program.enabled, rules: rules),
      program,
      epoch,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final reading = ref.watch(screenProgramProvider);
    final program = reading.isLoading || reading.hasError
        ? null
        : reading.value;
    final epoch = sessionGeneration;
    final enabled = _current(epoch) && !_saving;
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          l10n.screenProgramTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 740),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(l10n.screenProgramHint, style: AppText.body),
                  const SizedBox(height: 12),
                  if (reading.isLoading)
                    const Center(child: CupertinoActivityIndicator())
                  else if (program == null)
                    Text(l10n.screenProgramSaveFailed)
                  else ...[
                    MergeSemantics(
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              l10n.screenProgramEnabled,
                              style: AppText.headline,
                            ),
                          ),
                          CupertinoSwitch(
                            key: const ValueKey('screen-program-enabled'),
                            value: program.enabled,
                            onChanged: enabled
                                ? (value) => _save(
                                    ScreenProgram(
                                      enabled: value,
                                      rules: program.rules,
                                    ),
                                    program,
                                    epoch,
                                  )
                                : null,
                          ),
                        ],
                      ),
                    ),
                    Text(l10n.screenProgramDefault, style: AppText.footnote),
                    const SizedBox(height: 16),
                    if (program.rules.isEmpty) Text(l10n.screenProgramEmpty),
                    for (var index = 0; index < program.rules.length; index++)
                      _ruleCard(program, index, enabled),
                    if (program.rules.length < ScreenProgram.maxRules)
                      CupertinoButton(
                        key: const ValueKey('screen-program-add'),
                        onPressed: enabled ? () => _edit(program) : null,
                        child: Text(l10n.screenProgramAdd),
                      ),
                  ],
                  if (_saving)
                    const Center(child: CupertinoActivityIndicator()),
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(
                        color: CupertinoColors.systemRed.resolveFrom(context),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Text(l10n.screenProgramPriority, style: AppText.footnote),
                  const SizedBox(height: 12),
                  Text(l10n.screenProgramLocalTime, style: AppText.footnote),
                  const SizedBox(height: 12),
                  Text(l10n.screenProgramLimit, style: AppText.footnote),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _ruleCard(ScreenProgram program, int index, bool enabled) {
    final rule = program.rules[index];
    final l10n = AppLocalizations.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CupertinoButton(
            key: ValueKey('screen-rule-${rule.id}'),
            padding: EdgeInsets.zero,
            onPressed: enabled ? () => _edit(program, rule) : null,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                rule.name.isEmpty
                    ? '${l10n.screenProgramRule} ${index + 1}'
                    : rule.name,
              ),
            ),
          ),
          Text(
            (rule.days.toList()..sort())
                .map((v) => _day(context, v))
                .join(', '),
          ),
          Text('${_time(rule.startMinutes)} – ${_time(rule.endMinutes)}'),
          if (!rule.enabled) Text(l10n.commonOff),
          Text(
            '${_awake(l10n, rule.awake)}${rule.dim ? ' · ${l10n.screenProgramDim}' : ''}',
          ),
          Wrap(
            alignment: WrapAlignment.end,
            children: [
              CupertinoButton(
                key: ValueKey('screen-rule-up-${rule.id}'),
                onPressed: enabled && index > 0
                    ? () => _move(program, index, -1)
                    : null,
                child: Icon(
                  CupertinoIcons.arrow_up,
                  semanticLabel: l10n.dashboardMoveUp,
                ),
              ),
              CupertinoButton(
                key: ValueKey('screen-rule-down-${rule.id}'),
                onPressed: enabled && index < program.rules.length - 1
                    ? () => _move(program, index, 1)
                    : null,
                child: Icon(
                  CupertinoIcons.arrow_down,
                  semanticLabel: l10n.dashboardMoveDown,
                ),
              ),
              CupertinoButton(
                key: ValueKey('screen-rule-delete-${rule.id}'),
                onPressed: enabled ? () => _remove(program, rule) : null,
                child: Icon(
                  CupertinoIcons.delete,
                  semanticLabel: l10n.commonDelete,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ScreenRuleEditor extends ConsumerStatefulWidget {
  const _ScreenRuleEditor({required this.initial, required this.sourceCurrent});
  final ScreenProgramRule initial;
  final bool Function() sourceCurrent;
  @override
  ConsumerState<_ScreenRuleEditor> createState() => _ScreenRuleEditorState();
}

class _ScreenRuleEditorState extends MediaSessionState<_ScreenRuleEditor> {
  late final TextEditingController _name;
  late Set<int> _days;
  late int _start, _end;
  late ScreenAwakeMode _awakeMode;
  late bool _dim, _enabled;
  bool _expired = false;
  String? _error;
  Route<dynamic>? _modal;
  @override
  void initState() {
    super.initState();
    final rule = widget.initial;
    _name = TextEditingController(text: rule.name);
    _days = Set.of(rule.days);
    _start = rule.startMinutes;
    _end = rule.endMinutes;
    _awakeMode = rule.awake;
    _dim = rule.dim;
    _enabled = rule.enabled;
  }

  @override
  void clearPendingInteraction() {
    _expired = true;
    _name.clear();
    final modal = _modal;
    _modal = null;
    if (modal?.isActive == true) modal!.navigator?.removeRoute(modal);
  }

  bool get _ready =>
      sessionCurrent(sessionGeneration) && !_expired && widget.sourceCurrent();
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    if (!_ready ||
        _modal != null ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final rule = ScreenProgramRule(
      id: widget.initial.id,
      name: _name.text.trim(),
      days: _days,
      startMinutes: _start,
      endMinutes: _end,
      awake: _awakeMode,
      dim: _dim,
      enabled: _enabled,
    );
    try {
      if (_days.isEmpty || _start == _end) throw const FormatException();
      ScreenProgram(rules: [rule]).encode();
      Navigator.pop(context, rule);
    } catch (_) {
      setState(
        () => _error = AppLocalizations.of(context).screenProgramInvalid,
      );
    }
  }

  Future<void> _pickTime(bool start) async {
    if (!_ready ||
        _modal != null ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final epoch = sessionGeneration;
    var selected = start ? _start : _end;
    final l10n = AppLocalizations.of(context);
    final route = CupertinoModalPopupRoute<int>(
      builder: (modalContext) => Container(
        color: CupertinoColors.systemBackground.resolveFrom(modalContext),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CupertinoButton(
                onPressed: () {
                  if (_ready &&
                      epoch == sessionGeneration &&
                      ModalRoute.of(modalContext)?.isCurrent == true) {
                    Navigator.pop(modalContext, selected);
                  }
                },
                child: Text(l10n.commonDone),
              ),
              Flexible(
                child: SizedBox(
                  height: 216,
                  child: CupertinoDatePicker(
                    mode: CupertinoDatePickerMode.time,
                    use24hFormat: true,
                    initialDateTime: DateTime(
                      2026,
                      1,
                      5,
                      selected ~/ 60,
                      selected % 60,
                    ),
                    onDateTimeChanged: (value) {
                      if (_ready && epoch == sessionGeneration) {
                        selected = value.hour * 60 + value.minute;
                      }
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    _modal = route;
    final chosen = await Navigator.of(context).push(route);
    if (identical(_modal, route)) _modal = null;
    if (chosen != null && mounted && _ready && epoch == sessionGeneration) {
      setState(() {
        if (start) {
          _start = chosen;
        } else {
          _end = chosen;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final ready = _ready;
    final allDay = _start == 0 && _end == 1440;
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.screenProgramRule),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          key: const ValueKey('screen-rule-save'),
          onPressed: ready ? _save : null,
          child: Text(l10n.commonSave),
        ),
      ),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 700),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!ready) Text(l10n.screenProgramExpired),
                  CupertinoTextField(
                    key: const ValueKey('screen-rule-name'),
                    controller: _name,
                    enabled: ready,
                    maxLength: 60,
                    placeholder: l10n.screenProgramName,
                  ),
                  MergeSemantics(
                    child: Row(
                      children: [
                        Expanded(child: Text(l10n.adminEnabled)),
                        CupertinoSwitch(
                          key: const ValueKey('screen-rule-enabled'),
                          value: _enabled,
                          onChanged: ready
                              ? (value) => setState(() => _enabled = value)
                              : null,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(l10n.screenProgramDays, style: AppText.headline),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (var day = 1; day <= 7; day++)
                        Semantics(
                          selected: _days.contains(day),
                          button: true,
                          child: CupertinoButton(
                            key: ValueKey('screen-rule-day-$day'),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            color: _days.contains(day)
                                ? CupertinoColors.activeBlue
                                : null,
                            onPressed: ready
                                ? () => setState(() {
                                    if (!_days.remove(day)) _days.add(day);
                                  })
                                : null,
                            child: Text(
                              _day(context, day),
                              style: TextStyle(
                                color: _days.contains(day)
                                    ? CupertinoColors.white
                                    : null,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  MergeSemantics(
                    child: Row(
                      children: [
                        Expanded(child: Text(l10n.screenProgramAllDay)),
                        CupertinoSwitch(
                          key: const ValueKey('screen-rule-all-day'),
                          value: allDay,
                          onChanged: ready
                              ? (value) => setState(() {
                                  _start = value ? 0 : 22 * 60;
                                  _end = value ? 1440 : 7 * 60;
                                })
                              : null,
                        ),
                      ],
                    ),
                  ),
                  if (!allDay) ...[
                    CupertinoButton(
                      key: const ValueKey('screen-rule-start'),
                      onPressed: ready ? () => _pickTime(true) : null,
                      child: Text(
                        '${l10n.settingsNightStarts}: ${_time(_start)}',
                      ),
                    ),
                    CupertinoButton(
                      key: const ValueKey('screen-rule-end'),
                      onPressed: ready ? () => _pickTime(false) : null,
                      child: Text('${l10n.settingsNightEnds}: ${_time(_end)}'),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Text(l10n.screenProgramAwake, style: AppText.headline),
                  for (final mode in ScreenAwakeMode.values)
                    CupertinoButton(
                      key: ValueKey('screen-rule-mode-${mode.name}'),
                      onPressed: ready
                          ? () => setState(() => _awakeMode = mode)
                          : null,
                      child: Row(
                        children: [
                          Icon(
                            _awakeMode == mode
                                ? CupertinoIcons.check_mark_circled_solid
                                : CupertinoIcons.circle,
                          ),
                          const SizedBox(width: 12),
                          Expanded(child: Text(_awake(l10n, mode))),
                        ],
                      ),
                    ),
                  MergeSemantics(
                    child: Row(
                      children: [
                        Expanded(child: Text(l10n.screenProgramDim)),
                        CupertinoSwitch(
                          key: const ValueKey('screen-rule-dim'),
                          value: _dim,
                          onChanged: ready
                              ? (value) => setState(() => _dim = value)
                              : null,
                        ),
                      ],
                    ),
                  ),
                  Text(l10n.screenProgramDimHint, style: AppText.footnote),
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(
                        color: CupertinoColors.systemRed.resolveFrom(context),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
