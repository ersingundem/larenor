import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../auth/providers/auth_providers.dart';
import '../../navigation/presentation/app_shell_actions.dart';
import '../../navigation/search/domain/local_search_index.dart';
import '../data/today_timezone.dart';
import '../domain/today_models.dart';
import '../providers/today_providers.dart';
import 'today_support.dart';
import 'today_task_editor.dart';

enum _TodayView { overview, tasks, calendars, notifications, notification }

class TodayScreen extends ConsumerStatefulWidget {
  const TodayScreen({super.key}) : _view = _TodayView.overview, _id = null;
  const TodayScreen._(this._view, [this._id]);
  final _TodayView _view;
  final String? _id;
  @override
  ConsumerState<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends TodayConsumerState<TodayScreen> {
  final _pending = <String>{};
  final _search = TextEditingController();
  String _filter = 'all';
  Object? _error;
  String? _undoList;
  String? _undoUid;
  bool _confirmDismiss = false;

  @override
  void clearSession() {
    _pending.clear();
    _error = null;
    _undoList = null;
    _undoUid = null;
    _confirmDismiss = false;
    _search.clear();
    _filter = 'all';
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<bool> _run(String target, Future<void> Function() operation) async {
    if (!mounted || !foreground || _pending.contains(target)) return false;
    final epoch = generation;
    setState(() {
      _pending.add(target);
      _error = null;
    });
    try {
      await operation();
      return isCurrent(epoch);
    } catch (error) {
      if (isCurrent(epoch)) setState(() => _error = error);
      return false;
    } finally {
      if (isCurrent(epoch)) setState(() => _pending.remove(target));
    }
  }

  Future<void> _refresh() async {
    await _run('refresh', () async {
      if (ref.read(connectionConfigProvider).hasError) {
        ref.invalidate(connectionConfigProvider);
        ref.invalidate(todayProvider);
        return;
      }
      final controller = ref.read(todayControllerProvider);
      if (controller != null) {
        await controller.refresh();
      } else {
        ref.invalidate(todayProvider);
      }
    });
  }

  Future<void> _toggle(
    String listId,
    String uid,
    TodayTodoStatus status,
  ) async {
    final epoch = generation;
    final success = await _run(listId, () async {
      final snapshot = readSnapshot();
      final list = findTodayList(snapshot, listId);
      final item = findTodayItem(list, uid);
      final actions = ref.read(todayActionsProvider);
      if (snapshot == null ||
          list == null ||
          item == null ||
          actions == null ||
          !todayListWritable(snapshot, list) ||
          !list.canUpdate) {
        throw const TodayException('missing_item');
      }
      await actions.updateTodo(list, item, status: status);
    });
    if (success && isCurrent(epoch)) {
      setState(() {
        _undoList = status == TodayTodoStatus.completed ? listId : null;
        _undoUid = status == TodayTodoStatus.completed ? uid : null;
      });
    }
  }

  void _open(_TodayView view, {String? id}) {
    Navigator.of(
      context,
    ).push(CupertinoPageRoute<void>(builder: (_) => TodayScreen._(view, id)));
  }

  void _edit(TodayTodoList list, [TodayTodoItem? item]) {
    if (_pending.contains(list.entityId)) return;
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) =>
            TodayTaskEditor(listId: list.entityId, itemUid: item?.uid),
      ),
    );
  }

  void _viewNotification(TodayNotification item) {
    ref.read(todayControllerProvider)?.markNotificationRead(item.id);
    _open(_TodayView.notification, id: item.id);
  }

  bool _notificationsWritable(TodaySnapshot snapshot) =>
      snapshot.configured &&
      snapshot.notifications.value != null &&
      snapshot.notifications.issue == null &&
      !snapshot.issues.any(
        (issue) =>
            issue.source == TodaySource.configuration ||
            issue.source == TodaySource.notifications,
      );

  Future<void> _dismiss(String id) async {
    if (!_confirmDismiss) return;
    final epoch = generation;
    final success = await _run('notifications', () async {
      final snapshot = readSnapshot();
      final actions = ref.read(todayActionsProvider);
      if (snapshot == null ||
          actions == null ||
          !_notificationsWritable(snapshot) ||
          !snapshot.notifications.value!.any((item) => item.id == id)) {
        throw const TodayException('missing_item');
      }
      await actions.dismissNotification(id);
    });
    if (success && mounted && isCurrent(epoch)) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final snapshot = watchSnapshot();
    final asyncState = ref.watch(todayProvider);
    final connectionError = ref.watch(connectionConfigProvider).hasError;
    final actionsAvailable = ref.watch(todayActionsProvider) != null;
    final list = findTodayList(snapshot, widget._id ?? '');
    final title = switch (widget._view) {
      _TodayView.overview => l10n.todayTitle,
      _TodayView.tasks => list?.title ?? l10n.todayTodos,
      _TodayView.calendars => l10n.todayCalendar,
      _TodayView.notifications => l10n.todayNotifications,
      _TodayView.notification => l10n.todayNotificationFallback,
    };
    return AppPageScaffold(
      child: CustomScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const AppShellActions(),
          ),
          if (!foreground)
            const SliverFillRemaining(child: SizedBox())
          else if (snapshot == null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: asyncState.hasError || connectionError
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(l10n.todayReadError),
                          CupertinoButton(
                            onPressed: _refresh,
                            child: Text(l10n.commonRetry),
                          ),
                        ],
                      )
                    : const CupertinoActivityIndicator(),
              ),
            )
          else if (!snapshot.configured)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l10n.navigationUnconfigured,
                        textAlign: TextAlign.center,
                      ),
                      CupertinoButton(
                        onPressed: () => context.push('/settings'),
                        child: Text(l10n.navigationConfigure),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else ...[
            SliverToBoxAdapter(
              child: _constrained(
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget._view == _TodayView.overview &&
                          snapshot.dayStart != null)
                        Text(
                          todayDate(context, snapshot.dayStart!),
                          style: AppText.title2,
                        ),
                      if (snapshot.timeZone != null)
                        Text(
                          l10n.todayTimeZone(snapshot.timeZone!),
                          style: AppText.footnote,
                        ),
                      Text(
                        l10n.todayRefreshed(
                          todayTimestamp(
                            context,
                            snapshot.refreshedAt,
                            snapshot.timeZone,
                          ),
                        ),
                        style: AppText.footnote,
                      ),
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        onPressed: _pending.contains('refresh')
                            ? null
                            : _refresh,
                        child: _pending.contains('refresh')
                            ? const CupertinoActivityIndicator()
                            : Text(l10n.commonRefresh),
                      ),
                      if (snapshot.issues.isNotEmpty) ...[
                        Text(l10n.todayPartial, style: AppText.headline),
                        for (final failure
                            in snapshot.issues.map((e) => e.failure).toSet())
                          Text(
                            todayFailureLabel(l10n, failure),
                            style: AppText.footnote,
                          ),
                      ],
                      if (_error != null)
                        Text(
                          todayActionError(l10n, _error!),
                          key: const ValueKey('today-action-error'),
                          style: AppText.footnote,
                        ),
                      if (_undoList != null && _undoUid != null)
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 12,
                          children: [
                            Text(
                              l10n.todayMarkedComplete,
                              style: AppText.footnote,
                            ),
                            CupertinoButton(
                              key: const ValueKey('today-undo'),
                              onPressed: _pending.contains(_undoList)
                                  ? null
                                  : guarded(
                                      () => _toggle(
                                        _undoList!,
                                        _undoUid!,
                                        TodayTodoStatus.needsAction,
                                      ),
                                    ),
                              child: Text(l10n.todayUndo),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
            ...switch (widget._view) {
              _TodayView.overview => _overview(snapshot, actionsAvailable),
              _TodayView.tasks => _tasks(snapshot, list, actionsAvailable),
              _TodayView.calendars => _calendars(snapshot),
              _TodayView.notifications => _notifications(snapshot),
              _TodayView.notification => _notification(
                snapshot,
                actionsAvailable,
              ),
            },
            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ],
      ),
    );
  }

  Widget _constrained(Widget child) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1120),
      child: child,
    ),
  );

  List<Widget> _overview(TodaySnapshot snapshot, bool actionsAvailable) {
    final l10n = AppLocalizations.of(context);
    final cards = <Widget Function()>[
      if (snapshot.todoLists.isEmpty)
        () => TodayCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.todayTodos, style: AppText.title3),
              Text(
                snapshot.issues.any(
                      (issue) => issue.source == TodaySource.todos,
                    )
                    ? l10n.todayReadError
                    : l10n.todayNoTodoLists,
              ),
            ],
          ),
        ),
      for (final list in snapshot.todoLists)
        () => _todoCard(snapshot, list, actionsAvailable),
      () => TodayCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.todayCalendar, style: AppText.title3),
            if (snapshot.calendars.isEmpty)
              Text(
                snapshot.issues.any(
                      (issue) => issue.source == TodaySource.calendars,
                    )
                    ? l10n.todayReadError
                    : l10n.todayNoCalendars,
              ),
            for (final calendar in snapshot.calendars.take(3)) ...[
              const SizedBox(height: 12),
              Text(calendar.title, style: AppText.headline),
              TodayReadNotice(
                read: calendar.events,
                timeZone: snapshot.timeZone,
              ),
              if (calendar.events.value?.isEmpty == true &&
                  calendar.events.issue == null)
                Text(l10n.todayNoEvents, style: AppText.subhead),
              for (final event
                  in (calendar.events.value ?? <TodayCalendarEvent>[]).take(2))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        event.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        todayEventTime(context, event),
                        style: AppText.footnote,
                      ),
                    ],
                  ),
                ),
            ],
            if (snapshot.calendars.isNotEmpty)
              CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: guarded(() => _open(_TodayView.calendars)),
                child: Text(
                  l10n.todayViewAll(
                    snapshot.calendars.fold<int>(
                      0,
                      (sum, calendar) =>
                          sum + (calendar.events.value?.length ?? 0),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      () => TodayCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.todayNotifications, style: AppText.title3),
            TodayReadNotice(
              read: snapshot.notifications,
              timeZone: snapshot.timeZone,
            ),
            if (snapshot.notifications.value?.isEmpty == true &&
                snapshot.notifications.issue == null)
              Text(l10n.todayNoNotifications),
            for (final item
                in (snapshot.notifications.value ?? <TodayNotification>[]).take(
                  3,
                ))
              _notificationRow(item, snapshot),
            if (snapshot.notifications.value?.isNotEmpty == true)
              CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: guarded(() => _open(_TodayView.notifications)),
                child: Text(
                  l10n.todayViewAll(snapshot.notifications.value!.length),
                ),
              ),
          ],
        ),
      ),
    ];
    return [
      SliverLayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.crossAxisExtent >= 800 ? 2 : 1;
          return SliverList.builder(
            itemCount: (cards.length / columns).ceil(),
            itemBuilder: (context, row) => _constrained(
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var col = 0; col < columns; col++) ...[
                      if (col > 0) const SizedBox(width: 14),
                      Expanded(
                        child: row * columns + col < cards.length
                            ? cards[row * columns + col]()
                            : const SizedBox(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ];
  }

  Widget _todoCard(
    TodaySnapshot snapshot,
    TodayTodoList list,
    bool actionsAvailable,
  ) {
    final l10n = AppLocalizations.of(context);
    final items = list.items.value ?? const <TodayTodoItem>[];
    return TodayCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(list.title, style: AppText.title3),
          TodayReadNotice(read: list.items, timeZone: snapshot.timeZone),
          if (!list.available)
            Text(l10n.todayUnavailable, style: AppText.footnote),
          if (list.items.value != null)
            Text(
              l10n.todayRemaining(
                items
                    .where((item) => item.status == TodayTodoStatus.needsAction)
                    .length,
              ),
              style: AppText.footnote,
            ),
          if (items.isEmpty &&
              list.items.value != null &&
              list.items.issue == null)
            Text(l10n.todayNoTasks),
          for (final item in items.take(3))
            _todoRow(snapshot, list, item, actionsAvailable),
          Wrap(
            spacing: 12,
            children: [
              CupertinoButton(
                padding: EdgeInsets.zero,
                key: ValueKey('today-list-${list.entityId}'),
                onPressed: guarded(
                  () => _open(_TodayView.tasks, id: list.entityId),
                ),
                child: Text(l10n.todayViewAll(items.length)),
              ),
              if (list.canAdd)
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  key: ValueKey('today-add-${list.entityId}'),
                  onPressed:
                      actionsAvailable &&
                          todayListWritable(snapshot, list) &&
                          !_pending.contains(list.entityId)
                      ? guarded(() => _edit(list))
                      : null,
                  child: Text(l10n.todayAddTask),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _todoRow(
    TodaySnapshot snapshot,
    TodayTodoList list,
    TodayTodoItem item,
    bool actionsAvailable,
  ) {
    final l10n = AppLocalizations.of(context);
    final done = item.status == TodayTodoStatus.completed;
    final writable =
        actionsAvailable &&
        list.canUpdate &&
        item.canIdentify &&
        todayListWritable(snapshot, list) &&
        !_pending.contains(list.entityId);
    final label = item.summary?.isNotEmpty == true
        ? item.summary!
        : l10n.todayTaskUnnamed;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CupertinoButton(
            padding: const EdgeInsets.only(right: 12, top: 4, bottom: 8),
            key: ValueKey('today-toggle-${list.entityId}-${item.uid}'),
            onPressed: writable && item.status != TodayTodoStatus.unknown
                ? guarded(
                    () => _toggle(
                      list.entityId,
                      item.uid!,
                      done
                          ? TodayTodoStatus.needsAction
                          : TodayTodoStatus.completed,
                    ),
                  )
                : null,
            child: Semantics(
              label: done ? l10n.todayMarkIncomplete : l10n.todayMarkDone,
              child: Icon(
                done
                    ? CupertinoIcons.check_mark_circled_solid
                    : item.status == TodayTodoStatus.unknown
                    ? CupertinoIcons.question_circle
                    : CupertinoIcons.circle,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: AppText.body.copyWith(
                    decoration: done ? TextDecoration.lineThrough : null,
                  ),
                ),
                if (item.status == TodayTodoStatus.unknown)
                  Text(l10n.todayTaskUnknownStatus, style: AppText.footnote),
                if (item.dueDate != null)
                  Text(
                    todayDate(context, parseDateOnly(item.dueDate!)),
                    style: AppText.footnote,
                  ),
                if (item.dueAt != null)
                  Text(
                    todayTimestamp(context, item.dueAt!, snapshot.timeZone),
                    style: AppText.footnote,
                  ),
                if (widget._view == _TodayView.tasks &&
                    item.description?.isNotEmpty == true)
                  Text(item.description!, style: AppText.subhead),
                if (widget._view == _TodayView.tasks &&
                    list.canUpdate &&
                    item.canIdentify)
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    key: ValueKey('today-edit-${item.uid}'),
                    onPressed: writable
                        ? guarded(() => _edit(list, item))
                        : null,
                    child: Text(l10n.commonEdit),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _tasks(
    TodaySnapshot snapshot,
    TodayTodoList? list,
    bool actionsAvailable,
  ) {
    final l10n = AppLocalizations.of(context);
    if (list == null) return [_message(l10n.todayMissingItem)];
    final query = foldSearchText(_search.text);
    final items = (list.items.value ?? const <TodayTodoItem>[])
        .where(
          (item) =>
              (_filter == 'all' ||
                  (_filter == 'open'
                      ? item.status == TodayTodoStatus.needsAction
                      : item.status == TodayTodoStatus.completed)) &&
              foldSearchText('${item.summary ?? ''} ${item.description ?? ''}')
                  .contains(query),
        )
        .toList(growable: false);
    return [
      SliverToBoxAdapter(
        child: _constrained(
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TodayReadNotice(read: list.items, timeZone: snapshot.timeZone),
                if (!list.available) Text(l10n.todayUnavailable),
                if (!list.canUpdate)
                  Text(l10n.todayReadOnlyList, style: AppText.footnote),
                CupertinoSearchTextField(
                  controller: _search,
                  placeholder: l10n.commonSearch,
                  onChanged: (_) => setState(() {}),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final entry in {
                      'all': l10n.todayAllTasks,
                      'open': l10n.todayOpenTasks,
                      'completed': l10n.todayCompleted,
                    }.entries)
                      CupertinoButton(
                        onPressed: () => setState(() => _filter = entry.key),
                        child: Text(
                          entry.value,
                          style: TextStyle(
                            fontWeight: _filter == entry.key
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    if (list.canAdd)
                      CupertinoButton(
                        key: ValueKey('today-add-${list.entityId}'),
                        onPressed:
                            actionsAvailable &&
                                todayListWritable(snapshot, list) &&
                                !_pending.contains(list.entityId)
                            ? guarded(() => _edit(list))
                            : null,
                        child: Text(l10n.todayAddTask),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      if (items.isEmpty && list.items.value != null && list.items.issue == null)
        _message(
          _search.text.isNotEmpty
              ? l10n.navigationSearchEmpty
              : l10n.todayNoTasks,
        ),
      SliverList.builder(
        itemCount: items.length,
        itemBuilder: (context, index) => _constrained(
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: TodayCard(
              child: _todoRow(snapshot, list, items[index], actionsAvailable),
            ),
          ),
        ),
      ),
    ];
  }

  List<Widget> _calendars(TodaySnapshot snapshot) {
    final l10n = AppLocalizations.of(context);
    final builders = <Widget Function()>[];
    for (final calendar in snapshot.calendars) {
      builders.add(
        () => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(calendar.title, style: AppText.title3),
            TodayReadNotice(read: calendar.events, timeZone: snapshot.timeZone),
            if (calendar.events.value?.isEmpty == true &&
                calendar.events.issue == null)
              Text(l10n.todayNoEvents),
          ],
        ),
      );
      for (final event
          in calendar.events.value ?? const <TodayCalendarEvent>[]) {
        builders.add(
          () => TodayCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(event.title, style: AppText.headline),
                Text(todayEventTime(context, event), style: AppText.subhead),
                if (event.location?.isNotEmpty == true) ...[
                  const SizedBox(height: 8),
                  Text(l10n.todayLocation, style: AppText.footnote),
                  Text(event.location!),
                ],
                if (event.description?.isNotEmpty == true) ...[
                  const SizedBox(height: 8),
                  Text(event.description!, style: AppText.body),
                ],
              ],
            ),
          ),
        );
      }
    }
    return [
      SliverList.builder(
        itemCount: builders.length,
        itemBuilder: (context, index) => _constrained(
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: builders[index](),
          ),
        ),
      ),
    ];
  }

  Widget _notificationRow(TodayNotification item, TodaySnapshot snapshot) =>
      CupertinoButton(
        padding: const EdgeInsets.symmetric(vertical: 10),
        key: ValueKey('today-notification-${item.id}'),
        onPressed: guarded(() => _viewNotification(item)),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.title?.isNotEmpty == true
                    ? item.title!
                    : AppLocalizations.of(context).todayNotificationFallback,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.body.copyWith(
                  fontWeight: item.isRead ? FontWeight.normal : FontWeight.bold,
                ),
              ),
              Text(
                item.message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.subhead,
              ),
              Text(
                todayTimestamp(context, item.createdAt, snapshot.timeZone),
                style: AppText.footnote,
              ),
            ],
          ),
        ),
      );

  List<Widget> _notifications(TodaySnapshot snapshot) {
    final items = snapshot.notifications.value ?? const <TodayNotification>[];
    return [
      SliverToBoxAdapter(
        child: _constrained(
          Padding(
            padding: const EdgeInsets.all(20),
            child: TodayReadNotice(
              read: snapshot.notifications,
              timeZone: snapshot.timeZone,
            ),
          ),
        ),
      ),
      if (items.isEmpty &&
          snapshot.notifications.value != null &&
          snapshot.notifications.issue == null)
        _message(AppLocalizations.of(context).todayNoNotifications),
      SliverList.builder(
        itemCount: items.length,
        itemBuilder: (context, index) => _constrained(
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: TodayCard(child: _notificationRow(items[index], snapshot)),
          ),
        ),
      ),
    ];
  }

  List<Widget> _notification(TodaySnapshot snapshot, bool actionsAvailable) {
    final l10n = AppLocalizations.of(context);
    TodayNotification? item;
    for (final candidate
        in snapshot.notifications.value ?? const <TodayNotification>[]) {
      if (candidate.id == widget._id) item = candidate;
    }
    if (item == null) return [_message(l10n.todayMissingItem)];
    final notification = item;
    final canDismiss =
        actionsAvailable &&
        _notificationsWritable(snapshot) &&
        !_pending.contains('notifications');
    return [
      SliverToBoxAdapter(
        child: _constrained(
          Padding(
            padding: const EdgeInsets.all(20),
            child: TodayCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    notification.title ?? l10n.todayNotificationFallback,
                    style: AppText.title3,
                  ),
                  Text(
                    todayTimestamp(
                      context,
                      notification.createdAt,
                      snapshot.timeZone,
                    ),
                    style: AppText.footnote,
                  ),
                  const SizedBox(height: 12),
                  Text(notification.message),
                  const SizedBox(height: 16),
                  Text(
                    l10n.todayViewingKeepsNotification,
                    style: AppText.footnote,
                  ),
                  TodayReadNotice(
                    read: snapshot.notifications,
                    timeZone: snapshot.timeZone,
                  ),
                  if (_confirmDismiss) ...[
                    const SizedBox(height: 16),
                    Text(l10n.todayDismissConfirm, style: AppText.headline),
                    CupertinoButton(
                      key: const ValueKey('today-confirm-dismiss'),
                      onPressed: canDismiss
                          ? guarded(() => _dismiss(notification.id))
                          : null,
                      child: Text(l10n.todayDismissNotification),
                    ),
                    CupertinoButton(
                      onPressed: _pending.contains('notifications')
                          ? null
                          : () => setState(() => _confirmDismiss = false),
                      child: Text(l10n.commonCancel),
                    ),
                  ] else
                    CupertinoButton(
                      key: const ValueKey('today-dismiss'),
                      onPressed: canDismiss
                          ? guarded(
                              () => setState(() => _confirmDismiss = true),
                            )
                          : null,
                      child: Text(l10n.todayDismissNotification),
                    ),
                  if (_pending.contains('notifications'))
                    const CupertinoActivityIndicator(),
                ],
              ),
            ),
          ),
        ),
      ),
    ];
  }

  Widget _message(String text) => SliverToBoxAdapter(
    child: _constrained(
      Padding(padding: const EdgeInsets.all(20), child: Text(text)),
    ),
  );
}
