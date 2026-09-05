import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../auth/providers/auth_providers.dart';
import '../../../ha_client/providers/ha_client_providers.dart';
import '../../../health/data/health_configuration.dart';
import '../../ha_playback/providers/ha_playback_providers.dart';
import '../../ha_playback/data/ha_playback_api.dart';
import '../data/music_api.dart';
import '../data/music_playback_api.dart';
import '../data/music_playback_controller.dart';
import '../data/music_repository.dart';
import '../domain/music_playback_models.dart';
import 'music_providers.dart';

final musicPlaybackApiProvider = Provider.autoDispose<MusicPlaybackApi?>((ref) {
  final connection = ref.watch(connectionConfigProvider);
  if (connection.isLoading || connection.hasError || connection.value == null) {
    return null;
  }
  final ws = ref.watch(haWebSocketClientProvider);
  return ws == null ? null : WsMusicPlaybackApi(ws);
});
final musicPlaybackControllerProvider =
    Provider.autoDispose<MusicPlaybackController?>((ref) {
      final connection = ref.watch(connectionConfigProvider);
      final generation = ref.watch(musicAccountGenerationProvider);
      if (connection.isLoading ||
          connection.hasError ||
          connection.value == null ||
          generation == null) {
        return null;
      }
      final config = connection.value!;
      final api = ref.watch(musicPlaybackApiProvider);
      final reads = ref.watch(musicAssistantApiProvider);
      final inventory = ref.watch(haPlaybackApiProvider);
      if (api == null || reads == null || inventory == null) return null;
      bool current() {
        if (!ref.mounted) return false;
        final latest = ref.read(connectionConfigProvider);
        return !latest.isLoading &&
            !latest.hasError &&
            sameHealthConfiguration(config, latest.value) &&
            identical(generation, ref.read(musicAccountGenerationProvider));
      }

      final now = ref.watch(musicClockProvider);
      MusicPlaybackController? owner;
      bool active() => current() && (owner?.isActive ?? false);
      int scopeGeneration() => owner?.sessionGeneration ?? 0;
      // Reuse the socket, but add this route's generation to each internal
      // inventory request. Test adapters remain injectable through the base API.
      final freshInventory = inventory is WsHaPlaybackApi
          ? WsHaPlaybackApi(
              inventory.client,
              now: now,
              isCurrent: active,
              generation: scopeGeneration,
            )
          : inventory;
      final repository = MusicRepository(
        api: ScopedMusicAssistantApi(
          reads,
          isActive: active,
          generation: scopeGeneration,
        ),
        accountGeneration: generation,
        isCurrent: current,
        now: now,
        loadInventory: freshInventory.getInventory,
      );
      final controller = MusicPlaybackController(
        repository: repository,
        api: api,
        isCurrent: current,
        now: now,
      );
      owner = controller;
      final state = WidgetsBinding.instance.lifecycleState;
      controller.setForeground(
        state == null || state == AppLifecycleState.resumed,
      );
      final listener = AppLifecycleListener(
        onStateChange: (state) =>
            controller.setForeground(state == AppLifecycleState.resumed),
      );
      ref.onDispose(() {
        listener.dispose();
        controller.dispose();
      });
      // The route/dialog explicitly owns visibility. No read or mutation on build.
      return controller;
    });
final musicPlaybackStateProvider =
    StreamProvider.autoDispose<MusicPlaybackState>(
      (ref) =>
          ref.watch(musicPlaybackControllerProvider)?.changes ??
          Stream.value(const MusicPlaybackState()),
      retry: (_, _) => null,
    );
