import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/home_data_scope.dart';
import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../../shared/utils/foreground_poller.dart';
import '../../auth/providers/auth_providers.dart';
import '../../ha_client/data/ws_client.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../../health/providers/action_providers.dart';
import '../data/today_actions.dart';
import '../data/today_api.dart';
import '../data/today_controller.dart';
import '../data/today_repository.dart';
import '../data/today_retained_cache.dart';
import '../domain/today_daily_summary.dart';
import '../domain/today_models.dart';

/// Tests can replace the complete account-scoped transport without live calls.
final todayApiProvider = Provider.autoDispose<TodayApi?>((ref) {
  final connection = ref.watch(connectionConfigProvider);
  if (connection.isLoading || connection.hasError || connection.value == null) {
    return null;
  }
  final rest = ref.watch(haRestClientProvider);
  final ws = ref.watch(haWebSocketClientProvider);
  if (rest == null || ws == null) return null;
  // Keep the shared WS-backed snapshot alive, without rebuilding Today on
  // every entity update. Reconnect and foreground polling read its latest map.
  ref.listen(entitiesProvider, (_, _) {});
  return HaTodayApi(
    rest: rest,
    ws: ws,
    entities: () async =>
        (await ref.read(entitiesProvider.future)).values
            .toList(growable: false),
  );
});

final todayConnectionProvider = StreamProvider.autoDispose<HaConnectionStatus>(
  (ref) =>
      ref.watch(haWebSocketClientProvider)?.status ??
      Stream.value(HaConnectionStatus.disconnected),
);

final todayRetainedStoreProvider = Provider<TodayRetainedPersistence>(
  (_) => TodayRetainedStore(),
);

final todayRetainedScopeProvider = Provider.autoDispose<TodayRetainedScope?>((
  ref,
) {
  final home = ref.watch(homeSessionControllerProvider);
  if (home?.source == HomeSource.verifiedCore) {
    final session = home!.account.session;
    final context = session?.context;
    if (context == null || session == null || session.user.mustChangePassword) {
      return null;
    }
    try {
      return TodayRetainedScope.core(
        HomeDataScope.fromJson({
          'coreId': context.coreId,
          'homeId': context.homeId,
          'userId': session.user.id,
        }),
      );
    } catch (_) {
      return null;
    }
  }
  final config = ref.watch(connectionConfigProvider).value;
  if (config == null) return null;
  try {
    return TodayRetainedScope.direct(config);
  } catch (_) {
    return null;
  }
});

final class TodaySummarySelection {
  const TodaySummarySelection({
    required this.kind,
    this.sourceId,
    this.itemId,
    this.query = '',
  });

  final TodayDailySummaryKind kind;
  final String? sourceId;
  final String? itemId;
  final String query;
}

final todaySummarySelectionProvider =
    NotifierProvider<TodaySummarySelectionController, TodaySummarySelection?>(
      TodaySummarySelectionController.new,
    );

/// Navigation metadata only. Watching the opaque retained scope resets it on
/// account/home changes without starting a network read.
final class TodaySummarySelectionController
    extends Notifier<TodaySummarySelection?> {
  final _queries = <TodayDailySummaryKind, String>{};

  @override
  TodaySummarySelection? build() {
    ref.watch(todayRetainedScopeProvider)?.storageKey;
    _queries.clear();
    return null;
  }

  void select(TodayDailySummaryKind kind, {String? sourceId}) {
    _validateIdentity(sourceId);
    state = TodaySummarySelection(
      kind: kind,
      sourceId: sourceId,
      query: _queries[kind] ?? '',
    );
  }

  void updateQuery(String query) {
    final current = state;
    if (current == null ||
        query.length > 128 ||
        query.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw const TodayException('invalid_selection');
    }
    _queries[current.kind] = query;
    state = TodaySummarySelection(
      kind: current.kind,
      sourceId: current.sourceId,
      itemId: current.itemId,
      query: query,
    );
  }

  void selectItem({required String sourceId, required String itemId}) {
    final current = state;
    if (current == null) throw const TodayException('invalid_selection');
    _validateIdentity(sourceId);
    _validateIdentity(itemId);
    state = TodaySummarySelection(
      kind: current.kind,
      sourceId: sourceId,
      itemId: itemId,
      query: current.query,
    );
  }

  void reconcile(TodayDailySummary summary) {
    final current = state;
    if (current == null || current.itemId == null) return;
    final section = summary.sections
        .where((candidate) => candidate.kind == current.kind)
        .firstOrNull;
    final stillPresent = section?.entries.any(
      (entry) =>
          entry.sourceId == current.sourceId && entry.itemId == current.itemId,
    );
    if (stillPresent == true) return;
    state = TodaySummarySelection(kind: current.kind, query: current.query);
  }

  void reconcileSnapshot(TodaySnapshot snapshot) {
    final current = state;
    if (current == null || current.itemId == null) return;
    final stillPresent = switch (current.kind) {
      TodayDailySummaryKind.shopping || TodayDailySummaryKind.chores =>
        snapshot.todoLists
            .where((list) => list.entityId == current.sourceId)
            .any(
              (list) =>
                  list.items.value?.any((item) => item.uid == current.itemId) ==
                  true,
            ),
      TodayDailySummaryKind.calendar =>
        snapshot.calendars
            .where((calendar) => calendar.entityId == current.sourceId)
            .any(
              (calendar) =>
                  calendar.events.value?.any(
                    (event) => event.uid == current.itemId,
                  ) ==
                  true,
            ),
      TodayDailySummaryKind.notifications =>
        snapshot.notifications.value?.any(
              (notification) =>
                  notification.id == current.sourceId &&
                  notification.id == current.itemId,
            ) ==
            true,
    };
    if (stillPresent) return;
    state = TodaySummarySelection(kind: current.kind, query: current.query);
  }

  void clear() {
    _queries.clear();
    state = null;
  }

  void _validateIdentity(String? value) {
    if (value == null) return;
    if (value.isEmpty ||
        value.length > 256 ||
        value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw const TodayException('invalid_selection');
    }
  }
}

final todayControllerProvider = Provider.autoDispose<TodayController?>((ref) {
  final api = ref.watch(todayApiProvider);
  if (api == null) return null;
  final retainedScope = ref.watch(todayRetainedScopeProvider);
  final controller = TodayController(
    repository: TodayRepository(api: api),
    retainedStore: retainedScope == null
        ? null
        : ref.watch(todayRetainedStoreProvider),
    retainedScope: retainedScope,
  );
  final state = WidgetsBinding.instance.lifecycleState;
  controller.setForeground(state == null || state == AppLifecycleState.resumed);
  final lifecycle = AppLifecycleListener(
    onStateChange: (state) =>
        controller.setForeground(state == AppLifecycleState.resumed),
  );
  final poller = ForegroundPoller(
    interval: const Duration(seconds: 60),
    poll: controller.refresh,
  );
  ref.listen(todayConnectionProvider, (_, next) {
    final connected = next.value == HaConnectionStatus.connected;
    controller.setConnected(connected);
    if (connected) poller.refresh();
  }, fireImmediately: true);
  ref.onDispose(() {
    poller.dispose();
    lifecycle.dispose();
    controller.dispose();
  });
  poller.start();
  return controller;
});

final todayProvider = StreamProvider.autoDispose<TodaySnapshot>((ref) {
  final controller = ref.watch(todayControllerProvider);
  return controller?.changes ??
      Stream.value(
        TodaySnapshot(configured: false, refreshedAt: DateTime.now()),
      );
});

final todayActionsProvider = Provider.autoDispose<TodayActions?>((ref) {
  final controller = ref.watch(todayControllerProvider);
  if (controller == null) return null;
  return TodayActions(
    repository: controller.repository,
    controller: ref.watch(actionControllerProvider),
    onChanged: () => unawaited(controller.refresh(afterCurrent: true)),
  );
});
