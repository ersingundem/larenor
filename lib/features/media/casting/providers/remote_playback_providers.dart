import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../jellyfin/providers/jellyfin_providers.dart';
import '../data/remote_playback_api.dart';
import '../data/remote_playback_controller.dart';
import '../domain/remote_playback_models.dart';

final remotePlaybackApiProvider = Provider.autoDispose<RemotePlaybackApi?>((
  ref,
) {
  final connection = ref.watch(jellyfinConnectionProvider);
  if (connection.isLoading || connection.hasError || connection.value == null) {
    return null;
  }
  final client = ref.watch(jellyfinClientProvider);
  return client == null ? null : JellyfinRemotePlaybackApi(client);
});
final remotePlaybackClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);
final remotePlaybackControllerProvider =
    Provider.autoDispose<RemotePlaybackController?>((ref) {
      final connection = ref.watch(jellyfinConnectionProvider);
      final config = connection.isLoading || connection.hasError
          ? null
          : connection.value;
      if (config == null) return null;
      final api = ref.watch(remotePlaybackApiProvider);
      if (api == null) return null;
      bool current() {
        if (!ref.mounted) return false;
        final value = ref.read(jellyfinConnectionProvider);
        return !value.isLoading &&
            !value.hasError &&
            identical(value.value, config);
      }

      final controller = RemotePlaybackController(
        api: api,
        userId: config.userId,
        localDeviceId: config.deviceId,
        isCurrent: current,
        now: ref.watch(remotePlaybackClockProvider),
      );
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
final remotePlaybackProvider =
    StreamProvider.autoDispose<RemotePlaybackSnapshot>(
      (ref) =>
          ref.watch(remotePlaybackControllerProvider)?.changes ??
          Stream.value(RemotePlaybackSnapshot(configured: false)),
      retry: (_, _) => null,
    );
