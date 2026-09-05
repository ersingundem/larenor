import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../auth/providers/auth_providers.dart';
import '../../../ha_client/providers/ha_client_providers.dart';
import '../../../ha_client/data/ws_client.dart';
import '../../../health/data/health_configuration.dart';
import '../data/ha_playback_api.dart';
import '../data/ha_playback_controller.dart';
import '../domain/ha_media_inventory.dart';
import '../domain/ha_playback_models.dart';

final haPlaybackClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);
final haPlaybackApiProvider = Provider.autoDispose<HaPlaybackApi?>((ref) {
  final connection = ref.watch(connectionConfigProvider);
  final config = connection.isLoading || connection.hasError
      ? null
      : connection.value;
  if (config == null) return null;
  final client = ref.watch(haWebSocketClientProvider);
  if (client == null) return null;
  final state = WidgetsBinding.instance.lifecycleState;
  var foreground = state == null || state == AppLifecycleState.resumed;
  var generation = 0;
  var wasConnected = false;
  final status = client.status.listen((state) {
    final connected = state == HaConnectionStatus.connected;
    if (wasConnected && !connected) generation++;
    wasConnected = connected;
  });
  ref.onDispose(status.cancel);
  final lifecycle = AppLifecycleListener(
    onStateChange: (state) {
      generation++;
      foreground = state == AppLifecycleState.resumed;
    },
  );
  ref.onDispose(lifecycle.dispose);
  bool current() {
    if (!ref.mounted || !foreground) return false;
    final latest = ref.read(connectionConfigProvider);
    return !latest.isLoading &&
        !latest.hasError &&
        sameHealthConfiguration(config, latest.value);
  }

  return WsHaPlaybackApi(
    client,
    now: ref.watch(haPlaybackClockProvider),
    isCurrent: current,
    generation: () => generation,
  );
});

/// Shared passive read seam for the music output inventory; no polling/retry.
final haMediaInventoryProvider = FutureProvider.autoDispose<HaMediaInventory?>((
  ref,
) async {
  final api = ref.watch(haPlaybackApiProvider);
  if (api == null) return null;
  try {
    return await api.getInventory();
  } catch (error) {
    throw HaPlaybackException(haPlaybackFailure(error));
  }
}, retry: (_, _) => null);

final haPlaybackControllerProvider =
    Provider.autoDispose<HaPlaybackController?>((ref) {
      final connection = ref.watch(connectionConfigProvider);
      final config = connection.isLoading || connection.hasError
          ? null
          : connection.value;
      if (config == null) return null;
      final api = ref.watch(haPlaybackApiProvider);
      if (api == null) return null;
      bool current() {
        if (!ref.mounted) return false;
        final latest = ref.read(connectionConfigProvider);
        return !latest.isLoading &&
            !latest.hasError &&
            sameHealthConfiguration(config, latest.value);
      }

      final controller = HaPlaybackController(
        api: api,
        isCurrent: current,
        now: ref.watch(haPlaybackClockProvider),
      );
      // A route must explicitly activate this controller before any read.
      controller.setVisible(false);
      final state = WidgetsBinding.instance.lifecycleState;
      controller.setForeground(
        state == null || state == AppLifecycleState.resumed,
      );
      final lifecycle = AppLifecycleListener(
        onStateChange: (state) =>
            controller.setForeground(state == AppLifecycleState.resumed),
      );
      ref.onDispose(() {
        lifecycle.dispose();
        controller.dispose();
      });
      return controller;
    });
final haPlaybackProvider = StreamProvider.autoDispose<HaPlaybackSnapshot>(
  (ref) =>
      ref.watch(haPlaybackControllerProvider)?.changes ??
      Stream.value(const HaPlaybackSnapshot(configured: false)),
  retry: (_, _) => null,
);
