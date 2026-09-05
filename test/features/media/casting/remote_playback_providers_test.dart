import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/casting/domain/remote_playback_models.dart';
import 'package:larenor/features/media/casting/providers/remote_playback_providers.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';

import 'remote_playback_fixture.dart';

class _Connection extends JellyfinConnection {
  @override
  Future<JellyfinConfig?> build() async => const JellyfinConfig(
    baseUrl: 'https://jellyfin.test',
    userId: userId,
    accessToken: 'first-fixture',
    deviceId: 'local-tablet',
  );
  void replace() => state = const AsyncData(
    JellyfinConfig(
      baseUrl: 'https://jellyfin.test',
      userId: userId,
      accessToken: 'replacement-fixture',
      deviceId: 'local-tablet',
    ),
  );
}

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(Duration.zero);
  }
}

void main() {
  testWidgets(
    'same server new token discards old pending session discovery without network mutation',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final first = FakeRemoteApi()..targetGate = Completer<void>();
      final replacement = FakeRemoteApi()
        ..targets = [target(id: 'new-session', device: 'new-device')];
      final container = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          jellyfinConnectionProvider.overrideWith(_Connection.new),
          remotePlaybackApiProvider.overrideWith((ref) {
            final config = ref.watch(jellyfinConnectionProvider);
            if (config.isLoading || config.hasError) return null;
            return config.value?.accessToken == 'first-fixture'
                ? first
                : replacement;
          }),
          remotePlaybackClockProvider.overrideWithValue(() => remoteNow),
        ],
      );
      addTearDown(container.dispose);
      final listener = container.listen(remotePlaybackProvider, (_, _) {});
      await frames(tester);
      expect(first.reads, 1);
      final old = container.read(remotePlaybackControllerProvider)!;
      (container.read(jellyfinConnectionProvider.notifier) as _Connection)
          .replace();
      await frames(tester);
      expect(old.state.configured, isFalse);
      expect(
        container.read(remotePlaybackProvider).value?.targets.single.sessionId,
        'new-session',
      );
      first.targetGate!.complete();
      await frames(tester);
      expect(
        container.read(remotePlaybackProvider).value?.targets.single.sessionId,
        'new-session',
      );
      expect(first.commands, isEmpty);
      expect(replacement.commands, isEmpty);
      listener.close();
      container.dispose();
      await frames(tester);
    },
  );
  testWidgets(
    'background invalidates prepared confirmation and foreground re-reads targets',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final api = FakeRemoteApi();
      final container = ProviderContainer(
        overrides: [
          jellyfinConnectionProvider.overrideWith(_Connection.new),
          remotePlaybackApiProvider.overrideWith((_) => api),
          remotePlaybackClockProvider.overrideWithValue(() => remoteNow),
        ],
      );
      addTearDown(container.dispose);
      final listener = container.listen(remotePlaybackProvider, (_, _) {});
      await frames(tester);
      final controller = container.read(remotePlaybackControllerProvider)!;
      final intent = await controller.createIntent(
        controller.state.targets.single,
        itemId,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await frames(tester);
      await tester.pump(const Duration(minutes: 5));
      expect(api.reads, 1);
      expect(controller.state.targets, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await frames(tester);
      expect(api.reads, 2);
      await expectLater(
        controller.play(intent),
        throwsA(
          isA<RemotePlaybackException>().having(
            (error) => error.failure,
            'expired generation',
            RemotePlaybackFailure.invalidIntent,
          ),
        ),
      );
      expect(api.commands, isEmpty);
      listener.close();
      container.dispose();
      await frames(tester);
    },
  );
}
