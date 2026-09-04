import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/utils/foreground_poller.dart';
import '../../auth/providers/auth_providers.dart';
import '../../ha_client/data/ws_client.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../../health/providers/action_providers.dart';
import '../data/today_actions.dart';
import '../data/today_api.dart';
import '../data/today_controller.dart';
import '../data/today_repository.dart';
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

final todayControllerProvider = Provider.autoDispose<TodayController?>((ref) {
  final api = ref.watch(todayApiProvider);
  if (api == null) return null;
  final controller = TodayController(repository: TodayRepository(api: api));
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
