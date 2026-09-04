import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../data/today_timezone.dart';
import '../domain/today_models.dart';
import '../providers/today_providers.dart';
import 'today_support.dart';

/// Drafts exist only while this account and foreground editor remain active.
class TodayTaskEditor extends ConsumerStatefulWidget {
  const TodayTaskEditor({super.key, required this.listId, this.itemUid});
  final String listId;
  final String? itemUid;
  @override
  ConsumerState<TodayTaskEditor> createState() => _TodayTaskEditorState();
}

class _TodayTaskEditorState extends TodayConsumerState<TodayTaskEditor> {
  final _title = TextEditingController();
  final _notes = TextEditingController();
  bool _initialized = false;
  bool _expired = false;
  bool _busy = false;
  bool _titleRequired = false;
  Object? _error;
  String? _initialTitle;
  String? _initialNotes;
  bool _hadDue = false;
  bool _hasDue = false;
  bool _timed = false;
  bool _dueChanged = false;
  DateTime? _date;

  @override
  void clearSession() {
    _expired = true;
    _title.clear();
    _notes.clear();
    _initialTitle = null;
    _initialNotes = null;
    _date = null;
    _error = null;
    _busy = false;
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _initialize(TodaySnapshot snapshot, TodayTodoItem? item) {
    if (_initialized) return;
    _initialized = true;
    _title.text = item?.summary ?? '';
    _notes.text = item?.description ?? '';
    _initialTitle = _title.text;
    _initialNotes = _notes.text;
    _hasDue = item?.dueDate != null || item?.dueAt != null;
    _hadDue = _hasDue;
    _timed = item?.dueAt != null;
    var value = snapshot.dayStart ?? DateTime.now();
    if (item?.dueDate != null) {
      value = parseDateOnly(item!.dueDate!);
    } else if (item?.dueAt != null && snapshot.timeZone != null) {
      value = TodayTimeZone(snapshot.timeZone!).local(item!.dueAt!);
    }
    // The picker represents wall-clock components, not an instant in the
    // device timezone. Conversion to HA's named timezone happens only on Save.
    _date = DateTime(
      value.year,
      value.month,
      value.day,
      value.hour,
      value.minute,
    );
  }

  Future<void> _save() async {
    if (_busy || _expired || !foreground) return;
    if (_title.text.trim().isEmpty) {
      setState(() => _titleRequired = true);
      return;
    }
    final epoch = generation;
    setState(() {
      _busy = true;
      _error = null;
      _titleRequired = false;
    });
    try {
      final snapshot = readSnapshot();
      final list = findTodayList(snapshot, widget.listId);
      final item = findTodayItem(list, widget.itemUid);
      final actions = ref.read(todayActionsProvider);
      final adding = widget.itemUid == null;
      if (snapshot == null ||
          list == null ||
          actions == null ||
          !todayListWritable(snapshot, list) ||
          (adding ? !list.canAdd : !list.canUpdate || item == null)) {
        throw const TodayException('missing_item');
      }
      String? dueDate;
      DateTime? dueAt;
      if (_hasDue && (adding || _dueChanged)) {
        final date = _date!;
        if (_timed) {
          if (!list.canSetDueTime || snapshot.timeZone == null) {
            throw const TodayException('unsupported_due_time');
          }
          final location = TodayTimeZone(snapshot.timeZone!).location;
          final value = tz.TZDateTime(
            location,
            date.year,
            date.month,
            date.day,
            date.hour,
            date.minute,
          );
          if (value.year != date.year ||
              value.month != date.month ||
              value.day != date.day ||
              value.hour != date.hour ||
              value.minute != date.minute) {
            throw const TodayException('invalid_date');
          }
          dueAt = value;
        } else {
          if (!list.canSetDueDate) {
            throw const TodayException('unsupported_due_date');
          }
          dueDate =
              '${date.year.toString().padLeft(4, '0')}-'
              '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
        }
      }
      if (adding) {
        await actions.addTodo(
          list,
          _title.text.trim(),
          dueDate: dueDate,
          dueAt: dueAt,
          description: list.canSetDescription && _notes.text.isNotEmpty
              ? _notes.text
              : null,
        );
      } else {
        final titleChanged = _title.text.trim() != _initialTitle;
        final notesChanged =
            list.canSetDescription && _notes.text != _initialNotes;
        if (titleChanged ||
            notesChanged ||
            (_dueChanged && (_hasDue || _hadDue))) {
          await actions.updateTodo(
            list,
            item!,
            summary: titleChanged ? _title.text.trim() : null,
            description: notesChanged && _notes.text.isNotEmpty
                ? _notes.text
                : null,
            clearDescription: notesChanged && _notes.text.isEmpty,
            dueDate: dueDate,
            dueAt: dueAt,
            clearDue: _dueChanged && _hadDue && !_hasDue,
          );
        }
      }
      if (mounted && isCurrent(epoch)) Navigator.of(context).pop();
    } catch (error) {
      if (isCurrent(epoch)) setState(() => _error = error);
    } finally {
      if (isCurrent(epoch)) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final snapshot = watchSnapshot();
    final list = findTodayList(snapshot, widget.listId);
    final item = findTodayItem(list, widget.itemUid);
    final found =
        snapshot != null &&
        list != null &&
        (widget.itemUid == null || item != null);
    if (found && !_expired) _initialize(snapshot, item);
    final writable =
        found &&
        !_expired &&
        foreground &&
        todayListWritable(snapshot, list) &&
        (widget.itemUid == null ? list.canAdd : list.canUpdate) &&
        ref.watch(todayActionsProvider) != null;
    return PopScope(
      canPop: !_busy,
      child: AppPageScaffold(
        navigationBar: CupertinoNavigationBar(
          middle: Text(
            widget.itemUid == null ? l10n.todayAddTask : l10n.todayEditTask,
          ),
          leading: CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: Text(l10n.commonCancel),
          ),
        ),
        child: SafeArea(
          child: !foreground
              ? const SizedBox.expand()
              : SingleChildScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.all(20),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 640),
                      child: !_expired && found
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(list.title, style: AppText.title3),
                                TodayReadNotice(
                                  read: list.items,
                                  timeZone: snapshot.timeZone,
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  l10n.todayTaskTitle,
                                  style: AppText.headline,
                                ),
                                const SizedBox(height: 8),
                                CupertinoTextField(
                                  key: const ValueKey('today-task-title'),
                                  controller: _title,
                                  enabled: writable && !_busy,
                                  placeholder: l10n.todayTaskTitle,
                                  maxLength: 4096,
                                  maxLines: 3,
                                  minLines: 1,
                                  textCapitalization:
                                      TextCapitalization.sentences,
                                  onChanged: (_) {
                                    if (_titleRequired) {
                                      setState(() => _titleRequired = false);
                                    }
                                  },
                                ),
                                if (_titleRequired)
                                  Text(
                                    l10n.todayTaskTitleRequired,
                                    style: AppText.footnote,
                                  ),
                                if (list.canSetDescription) ...[
                                  const SizedBox(height: 20),
                                  Text(
                                    l10n.todayTaskNotes,
                                    style: AppText.headline,
                                  ),
                                  const SizedBox(height: 8),
                                  CupertinoTextField(
                                    key: const ValueKey('today-task-notes'),
                                    controller: _notes,
                                    enabled: writable && !_busy,
                                    placeholder: l10n.todayTaskNotes,
                                    maxLength: 32768,
                                    maxLines: 8,
                                    minLines: 3,
                                    textCapitalization:
                                        TextCapitalization.sentences,
                                  ),
                                ],
                                if (list.canSetDueDate ||
                                    list.canSetDueTime) ...[
                                  const SizedBox(height: 20),
                                  Text(
                                    l10n.todayTaskDueDate,
                                    style: AppText.headline,
                                  ),
                                  if (snapshot.timeZone != null)
                                    Text(
                                      l10n.todayTimeZone(snapshot.timeZone!),
                                      style: AppText.footnote,
                                    ),
                                  if (!_hasDue)
                                    Text(
                                      l10n.todayTaskNoDueDate,
                                      style: AppText.subhead,
                                    ),
                                  if (_hasDue) ...[
                                    Text(
                                      _timed
                                          ? '${todayDate(context, _date!)} · ${todayTime(context, _date!)}'
                                          : todayDate(context, _date!),
                                      style: AppText.subhead,
                                    ),
                                    if (list.canSetDueDate &&
                                        list.canSetDueTime)
                                      Wrap(
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        spacing: 12,
                                        children: [
                                          Text(l10n.todayTaskIncludeTime),
                                          CupertinoSwitch(
                                            value: _timed,
                                            onChanged:
                                                writable &&
                                                    !_busy &&
                                                    snapshot.timeZone != null
                                                ? (value) => setState(() {
                                                    _timed = value;
                                                    _dueChanged = true;
                                                  })
                                                : null,
                                          ),
                                        ],
                                      ),
                                    IgnorePointer(
                                      ignoring: !writable || _busy,
                                      child: SizedBox(
                                        height: 216,
                                        child: CupertinoDatePicker(
                                          key: ValueKey('today-date-$_timed'),
                                          initialDateTime: _date,
                                          mode: _timed
                                              ? CupertinoDatePickerMode
                                                    .dateAndTime
                                              : CupertinoDatePickerMode.date,
                                          use24hFormat: true,
                                          onDateTimeChanged: (value) {
                                            if (!_expired &&
                                                !_busy &&
                                                foreground &&
                                                writable) {
                                              setState(() {
                                                _date = value;
                                                _dueChanged = true;
                                              });
                                            }
                                          },
                                        ),
                                      ),
                                    ),
                                  ],
                                  CupertinoButton(
                                    key: const ValueKey('today-change-due'),
                                    onPressed: writable && !_busy
                                        ? () => setState(() {
                                            _hasDue = !_hasDue;
                                            _dueChanged = true;
                                            if (!list.canSetDueDate) {
                                              _timed = true;
                                            }
                                          })
                                        : null,
                                    child: Text(
                                      _hasDue
                                          ? l10n.todayTaskRemoveDueDate
                                          : l10n.todayTaskDueDate,
                                    ),
                                  ),
                                ],
                                if (_error != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 16),
                                    child: Text(
                                      todayActionError(l10n, _error!),
                                      key: const ValueKey('today-editor-error'),
                                      style: AppText.footnote,
                                    ),
                                  ),
                                const SizedBox(height: 20),
                                CupertinoButton.filled(
                                  key: const ValueKey('today-save-task'),
                                  onPressed: writable && !_busy ? _save : null,
                                  child: _busy
                                      ? const CupertinoActivityIndicator()
                                      : Text(l10n.commonSave),
                                ),
                              ],
                            )
                          : Column(
                              children: [
                                Text(l10n.todayMissingItem),
                                CupertinoButton(
                                  onPressed: () => Navigator.of(context).pop(),
                                  child: Text(l10n.commonClose),
                                ),
                              ],
                            ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}
