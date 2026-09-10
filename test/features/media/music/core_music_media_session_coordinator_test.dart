import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/music/core/data/core_music_media_session_bridge.dart';
import 'package:larenor/features/media/music/core/data/core_music_media_session_coordinator.dart';
import 'package:larenor/features/media/music/core/data/core_music_playback_api.dart';
import 'package:larenor/features/media/music/core/data/core_music_targets_api.dart';
import 'package:larenor/features/media/music/core/data/core_music_targets_controller.dart';
import 'package:larenor/features/media/music/core/domain/core_music_playback_models.dart';
import 'package:larenor/features/media/music/core/domain/core_music_target_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'core_music_targets_test.dart' show discoveryFixture;

void main() {
  test(
    'authenticated lease dispatches one exact action and sign-out retires it',
    () async {
      var authorized = true;
      final lifecycle = ValueNotifier(0);
      final targets = _Targets();
      final playback = _Playback(targets);
      final controller = CoreMusicTargetsController(
        api: targets,
        playbackApi: playback,
        lifecycle: lifecycle,
        authorized: () => authorized,
      );
      controller.setVisible(true);
      await Future<void>.delayed(Duration.zero);
      controller.select('homepod-living');
      final platform = _Platform();
      final coordinator = CoreMusicMediaSessionCoordinator(
        controller: controller,
        platform: platform,
      );
      await Future<void>.delayed(Duration.zero);
      expect(platform.published.last.authorized, isFalse);

      await controller.execute(CoreMusicPlaybackOperation.play);
      coordinator.authorizeCurrent();
      await Future<void>.delayed(Duration.zero);
      expect(platform.published.last.authorized, isTrue);
      expect(platform.published.last.revision, 10);

      platform.events.add(
        CoreMusicMediaSessionAction(
          sessionId: '0' * 32,
          playerRevision: 10,
          action: CoreMusicNativeAction.pause,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(playback.calls, 2);
      expect(platform.published.last.revision, 11);
      expect(platform.published.last.authorized, isTrue);

      authorized = false;
      lifecycle.value++;
      await Future<void>.delayed(Duration.zero);
      expect(coordinator.controlsAuthorized, isFalse);
      expect(platform.clears, greaterThan(0));

      await coordinator.dispose();
      unawaited(platform.events.close());
      controller.dispose();
      lifecycle.dispose();
    },
  );
}

class _Published {
  const _Published(this.revision, this.authorized);
  final int revision;
  final bool authorized;
}

class _Platform implements CoreMusicMediaSessionPlatform {
  final events = StreamController<CoreMusicMediaSessionAction>();
  final published = <_Published>[];
  int clears = 0;

  @override
  Stream<CoreMusicMediaSessionAction> get actions => events.stream;

  @override
  Future<void> clear() async => clears++;

  @override
  Future<void> publish({
    required CoreMusicMediaSessionState state,
    required int playerRevision,
    required bool controlsAuthorized,
    required bool canSeek,
    required bool canVolume,
    required int? volumeLevel,
  }) async {
    published.add(_Published(playerRevision, controlsAuthorized));
  }
}

class _Targets implements CoreMusicTargetsApi {
  int revision = 9;
  String state = 'paused';

  @override
  Future<CoreMusicTargetInventory> read({
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw const LarenorServerException('cancelled');
    final json = jsonDecode(
      jsonEncode(discoveryFixture()['inventory']),
    ) as Map<String, dynamic>;
    json['playerRevision'] = revision;
    final target = (json['targets'] as List).single as Map<String, dynamic>;
    target['playbackState'] = state;
    (target['queue'] as Map<String, dynamic>)['state'] = state;
    return CoreMusicTargetInventory.fromJson(json);
  }
}

class _Playback implements CoreMusicPlaybackApi {
  _Playback(this.targets);
  final _Targets targets;
  int calls = 0;

  @override
  Future<CoreMusicPlaybackReceipt> execute({
    required CoreMusicTargetInventory inventory,
    required CoreMusicTarget target,
    required CoreMusicPlaybackOperation operation,
    int? volumeLevel,
    int? seekPosition,
    required bool Function() isCurrent,
  }) async {
    calls++;
    targets.revision++;
    targets.state = operation == CoreMusicPlaybackOperation.pause
        ? 'paused'
        : 'playing';
    return CoreMusicPlaybackReceipt(
      requestId: '$calls'.padLeft(32, '0'),
      targetId: target.id,
      operation: operation,
      state: CoreMusicReceiptState.succeeded,
      playerRevision: targets.revision,
    );
  }
}
