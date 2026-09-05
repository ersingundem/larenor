import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:go_router/go_router.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/today/data/today_actions.dart';
import 'package:larenor/features/today/data/today_controller.dart';
import 'package:larenor/features/today/data/today_timezone.dart';
import 'package:larenor/features/today/domain/today_models.dart';
import 'package:larenor/features/today/presentation/today_screen.dart';
import 'package:larenor/features/today/presentation/today_support.dart';
import 'package:larenor/features/today/presentation/today_task_editor.dart';
import 'package:larenor/features/today/providers/today_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

class _Connection extends ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async => const HaConnectionConfig(
    baseUrl: 'http://ha.invalid',
    token: 'test-token',
  );
  void change() => state = const AsyncData(
    HaConnectionConfig(baseUrl: 'http://second.invalid', token: 'test-second'),
  );
}

class _Actions implements TodayActions {
  final calls = <Map<String, Object?>>[];
  Completer<void>? pending;
  Object? failure;
  void Function(Map<String, Object?>)? onSuccess;
  Future<void> _call(Map<String, Object?> call) async {
    calls.add(call);
    await pending?.future;
    if (failure != null) throw failure!;
    onSuccess?.call(call);
  }

  @override
  Future<void> addTodo(
    TodayTodoList list,
    String summary, {
    String? dueDate,
    DateTime? dueAt,
    String? description,
  }) => _call({
    'kind': 'add',
    'list': list.entityId,
    'summary': summary,
    'date': dueDate,
    'time': dueAt,
    'description': description,
  });
  @override
  Future<void> updateTodo(
    TodayTodoList list,
    TodayTodoItem item, {
    String? summary,
    TodayTodoStatus? status,
    String? dueDate,
    DateTime? dueAt,
    String? description,
    bool clearDue = false,
    bool clearDescription = false,
  }) => _call({
    'kind': 'update',
    'list': list.entityId,
    'uid': item.uid,
    'summary': summary,
    'status': status,
    'date': dueDate,
    'time': dueAt,
    'description': description,
    'clearDue': clearDue,
    'clearDescription': clearDescription,
  });
  @override
  Future<void> dismissNotification(String id) =>
      _call({'kind': 'dismiss', 'id': id});
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Controller implements TodayController {
  int reads = 0;
  final viewed = <String>[];
  @override
  Future<void> refresh({bool afterCurrent = false}) async => reads++;
  @override
  void markNotificationRead(String id) => viewed.add(id);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _now = DateTime.utc(2026, 9, 5, 12);
const _task = TodayTodoItem(
  uid: 'uid-1',
  summary: 'Milk',
  status: TodayTodoStatus.needsAction,
);
TodayTodoList _list({
  List<TodayTodoItem> items = const [_task],
  TodayIssue? issue,
  bool unread = false,
  int features = 1 | 4 | 16 | 32 | 64,
}) => TodayTodoList(
  entityId: 'todo.shopping',
  title: 'Shopping',
  supportedFeatures: features,
  available: true,
  items: TodayRead(
    value: unread ? null : items,
    issue: issue,
    readAt: unread ? null : _now,
  ),
);
TodaySnapshot _snapshot({
  TodayTodoList? list,
  List<TodayCalendar> calendars = const [],
  TodayRead<List<TodayNotification>> notifications = const TodayRead(value: []),
  List<TodayIssue> issues = const [],
  bool configured = true,
}) => TodaySnapshot(
  configured: configured,
  refreshedAt: _now,
  timeZone: 'Europe/Istanbul',
  dayStart: TodayTimeZone('Europe/Istanbul').dayRange(_now).start,
  todoLists: [?list],
  calendars: calendars,
  notifications: notifications,
  issues: issues,
);

class _Harness {
  _Harness(this.current);
  TodaySnapshot current;
  final interaction = AppInteractionController();
  final actions = _Actions();
  final controller = _Controller();
  final connection = _Connection();
  final changes = StreamController<TodaySnapshot>.broadcast(sync: true);
  late ProviderContainer container;
  late GoRouter router;
  void publish(TodaySnapshot snapshot) {
    current = snapshot;
    changes.add(snapshot);
  }

  void error() => changes.addError(StateError('private-token-backend-detail'));
  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(600, 1100),
    double scale = 1,
    Locale locale = const Locale('en'),
    Widget? child,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(
      retry: (count, error) => null,
      overrides: [
        connectionConfigProvider.overrideWith(() => connection),
        todayProvider.overrideWith(
          (ref) => Stream.multi((sink) {
            sink.add(current);
            final subscription = changes.stream.listen(
              sink.add,
              onError: sink.addError,
            );
            sink.onCancel = subscription.cancel;
          }),
        ),
        todayActionsProvider.overrideWith((ref) => actions),
        todayControllerProvider.overrideWith((ref) => controller),
      ],
    );
    await container.read(connectionConfigProvider.future);
    router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => child ?? const TodayScreen()),
        GoRoute(
          path: '/settings',
          builder: (_, _) =>
              const CupertinoPageScaffold(child: Text('Guarded settings')),
        ),
      ],
    );
    addTearDown(() async {
      interaction.dispose();
      router.dispose();
      container.dispose();
      await changes.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: CupertinoApp.router(
          locale: locale,
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: AppInteractionScope(controller: interaction, child: child!),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      300,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 30,
    );
  } else {
    await tester.ensureVisible(finder);
  }
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _background(WidgetTester tester) async {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
    await tester.pump();
  }
}

Future<void> _resume(WidgetTester tester) async {
  for (final state in [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
    await tester.pump();
  }
}

void main() {
  testWidgets('idle erases a draft and old Save cannot run after waking', (
    tester,
  ) async {
    final h = _Harness(_snapshot(list: _list(features: 1 | 4)));
    await h.mount(tester);
    await _tap(tester, 'today-add-todo.shopping');
    await tester.enterText(
      find.byKey(const ValueKey('today-task-title')),
      'Private idle draft',
    );
    final save = tester
        .widget<CupertinoButton>(find.byKey(const ValueKey('today-save-task')))
        .onPressed!;
    h.interaction.setActive(false);
    await tester.pump();
    h.interaction.setActive(true);
    await tester.pump();
    save();
    await tester.pumpAndSettle();
    expect(find.text('Private idle draft'), findsNothing);
    expect(find.byKey(const ValueKey('today-save-task')), findsNothing);
    expect(h.actions.calls, isEmpty);
  });

  testWidgets('idle expires notification dismiss confirmation permanently', (
    tester,
  ) async {
    final h = _Harness(
      _snapshot(
        notifications: TodayRead(
          value: [
            TodayNotification(
              id: 'notice-idle',
              message: 'Private notice',
              createdAt: _now,
            ),
          ],
        ),
      ),
    );
    await h.mount(tester);
    await _tap(tester, 'today-notification-notice-idle');
    await _tap(tester, 'today-dismiss');
    final confirm = tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('today-confirm-dismiss')),
        )
        .onPressed!;
    h.interaction.setActive(false);
    await tester.pump();
    h.interaction.setActive(true);
    await tester.pump();
    confirm();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('today-confirm-dismiss')), findsNothing);
    expect(h.actions.calls, isEmpty);
  });
  testWidgets('unread, failed, empty and retained stale reads stay distinct', (
    tester,
  ) async {
    final harness = _Harness(_snapshot(list: _list(unread: true)));
    await harness.mount(tester);
    expect(find.text('Not read yet'), findsOneWidget);
    expect(find.text('No tasks in this list.'), findsNothing);
    harness.publish(_snapshot(list: _list(items: [])));
    await tester.pumpAndSettle();
    expect(find.text('No tasks in this list.'), findsOneWidget);
    const issue = TodayIssue(
      TodaySource.todos,
      TodayFailure.permission,
      entityId: 'todo.shopping',
    );
    harness.publish(
      _snapshot(
        list: _list(issue: issue),
        issues: [issue],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Milk'), findsOneWidget);
    expect(
      find.text('Showing an older saved view. Refresh before making changes.'),
      findsOneWidget,
    );
    final button = tester.widget<CupertinoButton>(
      find.byKey(const ValueKey('today-toggle-todo.shopping-uid-1')),
    );
    expect(button.onPressed, isNull);
    expect(harness.actions.calls, isEmpty);
  });

  testWidgets(
    'completion and undo target the UID despite duplicate summaries',
    (tester) async {
      final harness = _Harness(
        _snapshot(
          list: _list(
            items: [
              _task,
              const TodayTodoItem(
                uid: 'uid-2',
                summary: 'Milk',
                status: TodayTodoStatus.needsAction,
              ),
            ],
          ),
        ),
      );
      await harness.mount(tester);
      await _tap(tester, 'today-toggle-todo.shopping-uid-2');
      expect(harness.actions.calls.single['uid'], 'uid-2');
      expect(harness.actions.calls.single['status'], TodayTodoStatus.completed);
      await _tap(tester, 'today-undo');
      expect(harness.actions.calls.last['uid'], 'uid-2');
      expect(harness.actions.calls.last['status'], TodayTodoStatus.needsAction);
    },
  );

  testWidgets(
    'rapid completion taps send one request and errors are sanitized',
    (tester) async {
      final harness = _Harness(_snapshot(list: _list()));
      harness.actions.pending = Completer<void>();
      harness.actions.failure = StateError('private-token-backend-detail');
      await harness.mount(tester);
      final button = tester.widget<CupertinoButton>(
        find.byKey(const ValueKey('today-toggle-todo.shopping-uid-1')),
      );
      button.onPressed!();
      button.onPressed!();
      await tester.pump();
      expect(harness.actions.calls.length, 1);
      harness.actions.pending!.complete();
      await tester.pumpAndSettle();
      expect(find.text('The request could not be completed'), findsOneWidget);
      expect(find.textContaining('private-token'), findsNothing);
      expect(find.byKey(const ValueKey('today-undo')), findsNothing);
    },
  );

  testWidgets(
    'unknown UID/status and unsupported features do not offer writes',
    (tester) async {
      final harness = _Harness(
        _snapshot(
          list: _list(
            items: [
              const TodayTodoItem(
                summary: 'No UID',
                status: TodayTodoStatus.needsAction,
              ),
              const TodayTodoItem(uid: 'unknown', summary: 'No status'),
            ],
            features: 0,
          ),
        ),
      );
      await harness.mount(tester);
      for (final key in [
        'today-toggle-todo.shopping-null',
        'today-toggle-todo.shopping-unknown',
      ]) {
        expect(
          tester.widget<CupertinoButton>(find.byKey(ValueKey(key))).onPressed,
          isNull,
        );
      }
      expect(
        find.byKey(const ValueKey('today-add-todo.shopping')),
        findsNothing,
      );
      expect(find.text('Status unavailable'), findsOneWidget);
      expect(harness.actions.calls, isEmpty);
    },
  );

  testWidgets(
    'opening notifications is local; server dismissal requires a second explicit action',
    (tester) async {
      final harness = _Harness(
        _snapshot(
          notifications: TodayRead(
            value: [
              TodayNotification(
                id: 'notice-1',
                message: 'Check the door',
                title: 'Door',
                createdAt: _now,
              ),
            ],
          ),
        ),
      );
      await harness.mount(tester);
      await _tap(tester, 'today-notification-notice-1');
      expect(harness.controller.viewed, ['notice-1']);
      expect(harness.actions.calls, isEmpty);
      await _tap(tester, 'today-dismiss');
      expect(
        find.text(
          'This removes the notification from Home Assistant for everyone.',
        ),
        findsOneWidget,
      );
      expect(harness.actions.calls, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(harness.actions.calls, isEmpty);
      await _tap(tester, 'today-dismiss');
      await _tap(tester, 'today-confirm-dismiss');
      expect(harness.actions.calls.single, {
        'kind': 'dismiss',
        'id': 'notice-1',
      });
    },
  );

  testWidgets('all-day end is exclusive and timed event keeps HA timezone', (
    tester,
  ) async {
    final zone = TodayTimeZone('Europe/Istanbul');
    final allDay = TodayCalendarEvent(
      title: 'Day off',
      start: zone.date('2026-09-05'),
      end: zone.date('2026-09-06'),
      allDay: true,
      startDate: '2026-09-05',
      endDate: '2026-09-06',
    );
    final timed = TodayCalendarEvent(
      title: 'Dentist',
      start: zone.local(DateTime.utc(2026, 9, 5, 9)),
      end: zone.local(DateTime.utc(2026, 9, 5, 10)),
      allDay: false,
    );
    final harness = _Harness(
      _snapshot(
        calendars: [
          TodayCalendar(
            entityId: 'calendar.family',
            title: 'Family',
            events: TodayRead(value: [allDay, timed]),
          ),
        ],
      ),
    );
    await harness.mount(tester);
    expect(find.text('All day · Sep 5, 2026'), findsOneWidget);
    expect(find.textContaining('Sep 6, 2026'), findsNothing);
    expect(
      find.text('Sep 5, 2026 · 12:00 – Sep 5, 2026 · 13:00'),
      findsOneWidget,
    );
    expect(harness.actions.calls, isEmpty);
  });

  testWidgets(
    'add validates an empty title, gates metadata and saves one explicit request',
    (tester) async {
      final harness = _Harness(_snapshot(list: _list(features: 1 | 4)));
      await harness.mount(tester);
      await _tap(tester, 'today-add-todo.shopping');
      expect(find.byKey(const ValueKey('today-task-notes')), findsNothing);
      expect(find.byKey(const ValueKey('today-change-due')), findsNothing);
      await _tap(tester, 'today-save-task');
      expect(find.text('Enter a task name.'), findsOneWidget);
      expect(harness.actions.calls, isEmpty);
      await tester.enterText(
        find.byKey(const ValueKey('today-task-title')),
        ' Bread ',
      );
      await _tap(tester, 'today-save-task');
      expect(harness.actions.calls.single['kind'], 'add');
      expect(harness.actions.calls.single['summary'], 'Bread');
    },
  );

  testWidgets(
    'editing preserves unchanged timed due data and supports explicit field clearing',
    (tester) async {
      final item = TodayTodoItem(
        uid: 'uid-1',
        summary: 'Milk',
        status: TodayTodoStatus.needsAction,
        dueAt: DateTime.utc(2026, 9, 6, 8),
        description: '2 bottles',
      );
      final harness = _Harness(_snapshot(list: _list(items: [item])));
      await harness.mount(tester);
      await _tap(tester, 'today-list-todo.shopping');
      await _tap(tester, 'today-edit-uid-1');
      await tester.enterText(
        find.byKey(const ValueKey('today-task-title')),
        'Oat milk',
      );
      await tester.enterText(
        find.byKey(const ValueKey('today-task-notes')),
        '',
      );
      await _tap(tester, 'today-change-due');
      await _tap(tester, 'today-save-task');
      final call = harness.actions.calls.single;
      expect(call['uid'], 'uid-1');
      expect(call['summary'], 'Oat milk');
      expect(call['clearDue'], true);
      expect(call['clearDescription'], true);
      expect(call['time'], isNull);
    },
  );

  testWidgets('saving an unchanged editor performs no mutation', (
    tester,
  ) async {
    final harness = _Harness(_snapshot(list: _list(features: 1 | 4)));
    await harness.mount(tester);
    await _tap(tester, 'today-list-todo.shopping');
    await _tap(tester, 'today-edit-uid-1');
    await _tap(tester, 'today-save-task');
    expect(harness.actions.calls, isEmpty);
    expect(find.byType(TodayTaskEditor), findsNothing);
  });

  testWidgets(
    'account switch erases a draft and rejects a captured Save callback',
    (tester) async {
      final harness = _Harness(_snapshot(list: _list(features: 1 | 4)));
      await harness.mount(tester);
      await _tap(tester, 'today-add-todo.shopping');
      await tester.enterText(
        find.byKey(const ValueKey('today-task-title')),
        'Private draft',
      );
      final save = tester
          .widget<CupertinoButton>(
            find.byKey(const ValueKey('today-save-task')),
          )
          .onPressed!;
      harness.connection.change();
      await tester.pump();
      save();
      await tester.pumpAndSettle();
      expect(find.text('Private draft'), findsNothing);
      expect(find.byKey(const ValueKey('today-save-task')), findsNothing);
      expect(harness.actions.calls, isEmpty);
    },
  );

  testWidgets(
    'background clears drafts and notification confirmation rather than submitting',
    (tester) async {
      final harness = _Harness(_snapshot(list: _list(features: 1 | 4)));
      await harness.mount(tester);
      await _tap(tester, 'today-add-todo.shopping');
      await tester.enterText(
        find.byKey(const ValueKey('today-task-title')),
        'Private draft',
      );
      await _background(tester);
      expect(find.text('Private draft'), findsNothing);
      await _resume(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('today-save-task')), findsNothing);
      expect(harness.actions.calls, isEmpty);
    },
  );

  testWidgets(
    'old account snapshot and late action completion are not shown in a new account',
    (tester) async {
      final harness = _Harness(_snapshot(list: _list()));
      harness.actions.pending = Completer<void>();
      await harness.mount(tester);
      final button = tester.widget<CupertinoButton>(
        find.byKey(const ValueKey('today-toggle-todo.shopping-uid-1')),
      );
      button.onPressed!();
      await tester.pump();
      harness.connection.change();
      await tester.pump();
      expect(find.text('Milk'), findsNothing);
      harness.publish(
        _snapshot(
          list: _list(
            items: [
              const TodayTodoItem(uid: 'other', summary: 'Second household'),
            ],
          ),
        ),
      );
      harness.actions.pending!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Second household'), findsOneWidget);
      expect(find.text('Milk'), findsNothing);
      expect(find.byKey(const ValueKey('today-undo')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a top-level read error redacts previous values and offers explicit retry',
    (tester) async {
      final harness = _Harness(_snapshot(list: _list()));
      await harness.mount(tester);
      harness.error();
      await tester.pumpAndSettle();
      expect(find.text('Milk'), findsNothing);
      expect(find.text('This information could not be read.'), findsOneWidget);
      expect(find.textContaining('private-token'), findsNothing);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(harness.controller.reads, 1);
    },
  );

  testWidgets('large task collections render lazily and search locally', (
    tester,
  ) async {
    final harness = _Harness(
      _snapshot(
        list: _list(
          items: [
            for (var i = 0; i < 1000; i++)
              TodayTodoItem(
                uid: 'uid-$i',
                summary: 'Item ${i.toString().padLeft(4, '0')}',
                status: TodayTodoStatus.needsAction,
              ),
          ],
        ),
      ),
    );
    await harness.mount(tester);
    await _tap(tester, 'today-list-todo.shopping');
    expect(find.byType(TodayCard).evaluate().length, lessThan(20));
    await tester.enterText(find.byType(CupertinoSearchTextField), 'Item 0999');
    await tester.pumpAndSettle();
    expect(find.text('Item 0999'), findsNWidgets(2));
    expect(find.text('Item 0000'), findsNothing);
    expect(harness.controller.reads, 0);
  });

  testWidgets(
    'captured old-account action cannot target an identical UID in a new account',
    (tester) async {
      final harness = _Harness(_snapshot(list: _list()));
      await harness.mount(tester);
      final oldCallback = tester
          .widget<CupertinoButton>(
            find.byKey(const ValueKey('today-toggle-todo.shopping-uid-1')),
          )
          .onPressed!;
      harness.connection.change();
      await tester.pump();
      harness.publish(_snapshot(list: _list()));
      await tester.pumpAndSettle();
      oldCallback();
      await tester.pumpAndSettle();
      expect(harness.actions.calls, isEmpty);
    },
  );

  testWidgets('background invalidates a captured server-dismiss confirmation', (
    tester,
  ) async {
    final harness = _Harness(
      _snapshot(
        notifications: TodayRead(
          value: [
            TodayNotification(
              id: 'notice-1',
              message: 'Private notice',
              createdAt: _now,
            ),
          ],
        ),
      ),
    );
    await harness.mount(tester);
    await _tap(tester, 'today-notification-notice-1');
    await _tap(tester, 'today-dismiss');
    final confirm = tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('today-confirm-dismiss')),
        )
        .onPressed!;
    await _background(tester);
    expect(find.text('Private notice'), findsNothing);
    await _resume(tester);
    confirm();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('today-confirm-dismiss')), findsNothing);
    expect(harness.actions.calls, isEmpty);
  });

  testWidgets('pending notification dismissal cannot be duplicated', (
    tester,
  ) async {
    final harness = _Harness(
      _snapshot(
        notifications: TodayRead(
          value: [
            TodayNotification(
              id: 'notice-1',
              message: 'Notice',
              createdAt: _now,
            ),
          ],
        ),
      ),
    );
    harness.actions.pending = Completer<void>();
    await harness.mount(tester);
    await _tap(tester, 'today-notification-notice-1');
    await _tap(tester, 'today-dismiss');
    final confirm = tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('today-confirm-dismiss')),
        )
        .onPressed!;
    confirm();
    confirm();
    await tester.pump();
    expect(harness.actions.calls.length, 1);
    harness.actions.pending!.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a removed task cannot be saved through a stale editor button', (
    tester,
  ) async {
    final harness = _Harness(_snapshot(list: _list(features: 1 | 4)));
    await harness.mount(tester);
    await _tap(tester, 'today-list-todo.shopping');
    await _tap(tester, 'today-edit-uid-1');
    await tester.enterText(
      find.byKey(const ValueKey('today-task-title')),
      'Changed',
    );
    final save = tester
        .widget<CupertinoButton>(find.byKey(const ValueKey('today-save-task')))
        .onPressed!;
    harness.publish(_snapshot(list: _list(items: [])));
    await tester.pump();
    save();
    await tester.pumpAndSettle();
    expect(harness.actions.calls, isEmpty);
    expect(
      find.text('This item is no longer available. Refresh the list.'),
      findsOneWidget,
    );
  });

  testWidgets('timed due date uses Home Assistant wall-clock components', (
    tester,
  ) async {
    final harness = _Harness(_snapshot(list: _list()));
    await harness.mount(tester);
    await _tap(tester, 'today-add-todo.shopping');
    await tester.enterText(
      find.byKey(const ValueKey('today-task-title')),
      'Appointment',
    );
    await _tap(tester, 'today-change-due');
    final toggle = tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch));
    toggle.onChanged!(true);
    await tester.pumpAndSettle();
    final picker = tester.widget<CupertinoDatePicker>(
      find.byType(CupertinoDatePicker),
    );
    picker.onDateTimeChanged(DateTime(2026, 9, 6, 10, 30));
    await tester.pumpAndSettle();
    await _tap(tester, 'today-save-task');
    final instant = harness.actions.calls.single['time']! as DateTime;
    expect(instant.toUtc(), DateTime.utc(2026, 9, 6, 7, 30));
    expect(harness.actions.calls.single['date'], isNull);
  });

  testWidgets(
    'late failed completion after page disposal never updates disposed UI',
    (tester) async {
      final harness = _Harness(_snapshot(list: _list()));
      harness.actions.pending = Completer<void>();
      harness.actions.failure = StateError('private-backend-detail');
      await harness.mount(tester);
      final toggle = tester
          .widget<CupertinoButton>(
            find.byKey(const ValueKey('today-toggle-todo.shopping-uid-1')),
          )
          .onPressed!;
      toggle();
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      harness.actions.pending!.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [const Size(320, 900), const Size(1100, 900)]) {
    testWidgets(
      'overview and editor fit ${size.width}px with Turkish text at 2x',
      (tester) async {
        final harness = _Harness(_snapshot(list: _list()));
        await harness.mount(
          tester,
          size: size,
          scale: 2,
          locale: const Locale('tr'),
        );
        expect(tester.takeException(), isNull);
        await _tap(tester, 'today-add-todo.shopping');
        expect(tester.takeException(), isNull);
        await _tap(tester, 'today-change-due');
        expect(tester.takeException(), isNull);
        await _tap(tester, 'today-save-task');
        expect(tester.takeException(), isNull);
      },
    );
  }
}
