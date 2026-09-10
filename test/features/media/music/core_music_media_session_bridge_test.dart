import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/music/core/data/core_music_media_session_bridge.dart';
import 'package:larenor/features/media/music/core/domain/core_music_playback_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('fixture/core_music_session');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('publish sends only bounded secret-free MediaSession state', () async {
    MethodCall? sent;
    messenger.setMockMethodCallHandler(channel, (call) async {
      sent = call;
      return true;
    });
    final bridge = CoreMusicMediaSessionBridge(
      methods: channel,
      isAndroid: true,
      sessionId: () => '6' * 32,
    );
    await bridge.publish(
      state: const CoreMusicMediaSessionState(
        targetId: 'homepod-living',
        title: 'Synthetic Song',
        positionSeconds: 37,
        durationSeconds: 241,
        isPlaying: true,
        canPlay: true,
        canPause: true,
        canNext: true,
        canPrevious: true,
      ),
      playerRevision: 11,
      controlsAuthorized: true,
      canSeek: true,
      canVolume: true,
      volumeLevel: 32,
    );
    expect(sent!.method, 'publish');
    expect(sent!.arguments, {
      'sessionId': '6' * 32,
      'playerRevision': 11,
      'title': 'Synthetic Song',
      'positionMs': 37000,
      'durationMs': 241000,
      'isPlaying': true,
      'isGroup': false,
      'canPlay': true,
      'canPause': true,
      'canNext': true,
      'canPrevious': true,
      'canSeek': true,
      'canVolume': true,
      'volumeLevel': 32,
      'controlsAuthorized': true,
    });
    expect(sent!.arguments.toString(), isNot(contains('homepod-living')));
    expect(sent!.arguments.toString(), isNot(contains('token')));
  });

  test(
    'action parser rejects stale shape, secret fields and out of range values',
    () {
      final valid = {
        'sessionId': '6' * 32,
        'playerRevision': 11,
        'action': 'seek',
        'value': 37000,
      };
      expect(
        CoreMusicMediaSessionAction.fromChannel(valid).action,
        CoreMusicNativeAction.seek,
      );
      for (final invalid in [
        {...valid, 'token': 'private'},
        {...valid, 'playerRevision': 0},
        {...valid, 'value': 604800001},
        {...valid, 'action': 'retry'},
      ]) {
        expect(
          () => CoreMusicMediaSessionAction.fromChannel(invalid),
          throwsA(isA<CoreMusicMediaSessionException>()),
        );
      }
    },
  );
}
