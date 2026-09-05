import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../auth/providers/auth_providers.dart';
import '../../../ha_client/providers/ha_client_providers.dart';
import '../../../health/data/health_configuration.dart';
import '../../ha_playback/providers/ha_playback_providers.dart';
import '../data/music_api.dart';
import '../data/music_queue_controller.dart';
import '../data/music_repository.dart';
import '../domain/music_models.dart';

final musicClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);
final musicForegroundProvider = Provider.autoDispose<bool>((ref) {
  final listener = AppLifecycleListener(
    onStateChange: (_) => ref.invalidateSelf(),
  );
  ref.onDispose(listener.dispose);
  final state = WidgetsBinding.instance.lifecycleState;
  return state == null || state == AppLifecycleState.resumed;
});

/// Opaque, ephemeral selection identity. Tokens and endpoint URLs never form
/// provider-family keys, diagnostics, or a persisted music selection.
final musicAccountGenerationProvider = Provider.autoDispose<Object?>((ref) {
  final connection = ref.watch(connectionConfigProvider);
  if (connection.isLoading || connection.hasError || connection.value == null) {
    return null;
  }
  return Object();
});
final musicAssistantApiProvider = Provider.autoDispose<MusicAssistantApi?>((
  ref,
) {
  final connection = ref.watch(connectionConfigProvider);
  if (connection.isLoading || connection.hasError || connection.value == null) {
    return null;
  }
  final ws = ref.watch(haWebSocketClientProvider);
  return ws == null ? null : WsMusicAssistantApi(ws);
});
final musicRepositoryProvider = Provider.autoDispose<MusicRepository?>((ref) {
  final connection = ref.watch(connectionConfigProvider);
  final generation = ref.watch(musicAccountGenerationProvider);
  final foreground = ref.watch(musicForegroundProvider);
  if (connection.isLoading ||
      connection.hasError ||
      connection.value == null ||
      generation == null ||
      !foreground) {
    return null;
  }
  final config = connection.value!;
  final api = ref.watch(musicAssistantApiProvider);
  if (api == null) return null;
  final now = ref.watch(musicClockProvider);
  bool current() {
    if (!ref.mounted) return false;
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null && state != AppLifecycleState.resumed) return false;
    final latest = ref.read(connectionConfigProvider);
    return !latest.isLoading &&
        !latest.hasError &&
        sameHealthConfiguration(config, latest.value) &&
        identical(generation, ref.read(musicAccountGenerationProvider));
  }

  var inventoryRetained = false;
  final repository = MusicRepository(
    api: api,
    accountGeneration: generation,
    isCurrent: current,
    now: now,
    loadInventory: () async {
      if (!current()) throw const MusicException(MusicFailure.stale);
      if (!inventoryRetained) {
        ref.listen(haMediaInventoryProvider, (_, _) {});
        inventoryRetained = true;
      }
      final cached = ref.read(haMediaInventoryProvider);
      final value = cached.value;
      if (!cached.isLoading &&
          (cached.hasError ||
              value == null ||
              now().isBefore(value.readAt) ||
              now().difference(value.readAt) >= const Duration(minutes: 1))) {
        ref.invalidate(haMediaInventoryProvider);
      }
      final inventory = await ref.read(haMediaInventoryProvider.future);
      if (!current()) throw const MusicException(MusicFailure.stale);
      if (inventory == null) {
        throw const MusicException(MusicFailure.notConfigured);
      }
      return inventory;
    },
  );
  ref.onDispose(repository.close);
  return repository;
});

final musicDiscoveryProvider = FutureProvider.autoDispose<MusicDiscovery>((
  ref,
) async {
  final generation = ref.watch(musicAccountGenerationProvider);
  final repository = ref.watch(musicRepositoryProvider);
  if (repository == null) {
    return MusicDiscovery(
      accountGeneration: generation ?? Object(),
      readAt: ref.read(musicClockProvider)(),
      configured: generation != null,
      issues: {
        MusicDiscoverySource.configEntries: generation == null
            ? MusicFailure.notConfigured
            : MusicFailure.stale,
      },
    );
  }
  return repository.discover();
}, retry: (_, _) => null);

final musicLibraryProvider = FutureProvider.autoDispose
    .family<MusicRead<MusicLibraryPage>, MusicLibraryQuery>((ref, query) async {
      final repository = ref.watch(musicRepositoryProvider);
      if (repository == null) {
        return const MusicRead(failure: MusicFailure.notConfigured);
      }
      try {
        final page = await repository.library(query);
        if (!ref.mounted) return const MusicRead(failure: MusicFailure.stale);
        return MusicRead(
          value: page,
          readAt: ref.read(musicClockProvider)().toUtc(),
        );
      } catch (error) {
        return MusicRead(failure: classifyMusicFailure(error));
      }
    }, retry: (_, _) => null);
final musicSearchProvider = FutureProvider.autoDispose
    .family<MusicRead<MusicSearchResults>, MusicSearchQuery>((
      ref,
      query,
    ) async {
      final repository = ref.watch(musicRepositoryProvider);
      if (repository == null) {
        return const MusicRead(failure: MusicFailure.notConfigured);
      }
      // Disposed keystroke families do not reach the server. Explicit submission may
      // use the same family; the small debounce never queues a playback command.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!ref.mounted) return const MusicRead(failure: MusicFailure.stale);
      try {
        final results = await repository.search(query);
        if (!ref.mounted) return const MusicRead(failure: MusicFailure.stale);
        return MusicRead(
          value: results,
          readAt: ref.read(musicClockProvider)().toUtc(),
        );
      } catch (error) {
        return MusicRead(failure: classifyMusicFailure(error));
      }
    }, retry: (_, _) => null);
final musicQueueControllerProvider = Provider.autoDispose
    .family<MusicQueueController?, MusicQueueQuery>((ref, query) {
      final repository = ref.watch(musicRepositoryProvider);
      if (repository == null) return null;
      final controller = MusicQueueController(
        read: () => repository.queue(query),
        now: ref.watch(musicClockProvider),
      );
      ref.onDispose(controller.dispose);
      return controller;
    });
final musicQueueProvider = StreamProvider.autoDispose
    .family<MusicRead<MusicQueueSummary>, MusicQueueQuery>((ref, query) {
      final controller = ref.watch(musicQueueControllerProvider(query));
      if (controller == null) {
        return Stream.value(
          const MusicRead(failure: MusicFailure.notConfigured),
        );
      }
      ref.onCancel(controller.stop);
      ref.onResume(controller.start);
      controller.start();
      return controller.changes;
    }, retry: (_, _) => null);
