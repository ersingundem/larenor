import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/local_audio/data/local_audio_bridge.dart';
import 'package:larenor/features/media/local_audio/domain/local_audio_models.dart';
import 'package:larenor/features/media/local_audio/providers/local_audio_providers.dart';

import 'local_audio_models_test.dart';

const methods = MethodChannel(LocalAudioBridge.methodChannelName);
const events = MethodChannel(LocalAudioBridge.eventChannelName);
const codec = StandardMethodCodec();

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  test(
    'source identity travels atomically with controls except video handoff',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        return null;
      });
      final bridge = LocalAudioBridge(isAndroid: true);
      await bridge.pause(expectedSourceId: 'station-one');
      await bridge.resume(expectedSourceId: 'station-one');
      await bridge.seek(
        const Duration(seconds: 2),
        expectedSourceId: 'station-one',
      );
      await bridge.stop(expectedSourceId: 'station-one');
      await bridge.stopForVideo();
      expect(calls.map((call) => call.arguments), [
        {'sourceId': 'station-one'},
        {'sourceId': 'station-one'},
        {'sourceId': 'station-one', 'positionMs': 2000},
        {'sourceId': 'station-one'},
        null,
      ]);
      expect(
        () => bridge.pause(expectedSourceId: 'https://secret.example'),
        throwsA(audioFailure(LocalAudioFailure.invalidSource)),
      );
      expect(calls, hasLength(5));
    },
  );

  test(
    'nonAndroid and missing native plugin are honest, repeatable no-op reads',
    () async {
      final other = LocalAudioBridge(isAndroid: false);
      expect((await other.snapshot()).supported, isFalse);
      expect((await other.changes.first).supported, isFalse);
      expect((await other.changes.first).supported, isFalse);
      expect((await other.readPowerStatus()).supported, isFalse);
      expect(await other.openBatterySettings(), isFalse);
      await other.stopForVideo();
      await expectLater(
        other.play(audioSource()),
        throwsA(audioFailure(LocalAudioFailure.unsupported)),
      );
      final missing = LocalAudioBridge(isAndroid: true);
      expect((await missing.snapshot()).supported, isFalse);
      expect((await missing.changes.first).supported, isFalse);
      expect((await missing.readPowerStatus()).supported, isFalse);
      await missing.stopForVideo();
    },
  );

  test(
    'typed method names and payload preserve metadata but never attach headers',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        return null;
      });
      final bridge = LocalAudioBridge(isAndroid: true);
      await bridge.play(audioSource());
      await bridge.pause();
      await bridge.resume();
      await bridge.seek(const Duration(milliseconds: 4200));
      await bridge.stopForVideo();
      expect(calls.map((call) => call.method), [
        'play',
        'pause',
        'resume',
        'seek',
        'stop',
      ]);
      final source = calls.first.arguments as Map;
      expect(
        source.keys,
        unorderedEquals(['id', 'uri', 'mimeType', 'title', 'artist', 'album']),
      );
      expect(source['id'], 'station-one');
      expect(source['title'], 'Station');
      expect(calls[3].arguments, 4200);
      expect(calls.last.arguments, isNull);
      expect(
        () => bridge.seek(const Duration(milliseconds: -1)),
        throwsA(audioFailure(LocalAudioFailure.invalidPosition)),
      );
      expect(calls, hasLength(5));
    },
  );

  test(
    'busy play cannot duplicate while stop can cancel before native launch',
    () async {
      final gate = Completer<void>();
      final calls = <String>[];
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call.method);
        if (call.method == 'play') await gate.future;
        return null;
      });
      final bridge = LocalAudioBridge(isAndroid: true);
      final first = bridge.play(audioSource());
      await expectLater(
        bridge.play(audioSource()),
        throwsA(audioFailure(LocalAudioFailure.busy)),
      );
      await bridge.stopForVideo();
      expect(calls, ['play', 'stop']);
      gate.complete();
      await first;
      expect(calls, ['play', 'stop']);
    },
  );

  test(
    'stopForVideo waits for native release and fails closed on real errors',
    () async {
      final gate = Completer<void>();
      messenger.setMockMethodCallHandler(methods, (_) async {
        await gate.future;
        return null;
      });
      final bridge = LocalAudioBridge(isAndroid: true);
      var videoOpened = false;
      final stop = bridge.stopForVideo().then((_) => videoOpened = true);
      await Future<void>.delayed(Duration.zero);
      expect(videoOpened, isFalse);
      gate.complete();
      await stop;
      expect(videoOpened, isTrue);
      messenger.setMockMethodCallHandler(
        methods,
        (_) async => throw PlatformException(
          code: 'unavailable',
          message: 'https://private.example?token=secret',
          details: {'password': 'secret'},
        ),
      );
      await expectLater(
        bridge.stopForVideo(),
        throwsA(audioFailure(LocalAudioFailure.unavailable)),
      );
      try {
        await bridge.play(audioSource());
      } on LocalAudioException catch (error) {
        expect(error.toString(), isNot(contains('secret')));
        expect(error.toString(), isNot(contains('private.example')));
      }
    },
  );

  testWidgets(
    'provider subscriptions share native events and closing UI never stops playback',
    (tester) async {
      final calls = <String>[];
      final eventCalls = <String>[];
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call.method);
        return audioSnapshot();
      });
      messenger.setMockMethodCallHandler(events, (call) async {
        eventCalls.add(call.method);
        return null;
      });
      final bridge = LocalAudioBridge(isAndroid: true);
      final container = ProviderContainer(
        overrides: [localAudioBridgeProvider.overrideWithValue(bridge)],
      );
      addTearDown(container.dispose);
      final one = container.listen(localAudioProvider, (_, _) {});
      final two = container.listen(localAudioProvider, (_, _) {});
      await frames(tester);
      expect(calls, ['snapshot']);
      expect(eventCalls, ['listen']);
      await messenger.handlePlatformMessage(
        LocalAudioBridge.eventChannelName,
        codec.encodeSuccessEnvelope(audioSnapshot(playing: true)),
        (_) {},
      );
      await frames(tester);
      expect(container.read(localAudioProvider).value?.isPlaying, isTrue);
      one.close();
      two.close();
      await frames(tester);
      expect(eventCalls, ['listen', 'cancel']);
      expect(calls, ['snapshot']);
      final reopened = container.listen(localAudioProvider, (_, _) {});
      await frames(tester);
      expect(eventCalls, ['listen', 'cancel', 'listen']);
      expect(calls, ['snapshot', 'snapshot']);
      reopened.close();
      container.dispose();
      await frames(tester);
      expect(calls, isNot(contains('stop')));
    },
  );

  testWidgets(
    'late snapshot after UI disposal cannot start native event listening',
    (tester) async {
      final pending = Completer<Object?>();
      var listens = 0;
      messenger.setMockMethodCallHandler(methods, (_) => pending.future);
      messenger.setMockMethodCallHandler(events, (_) async {
        listens++;
        return null;
      });
      final bridge = LocalAudioBridge(isAndroid: true);
      final subscription = bridge.changes.listen((_) {});
      unawaited(subscription.cancel());
      pending.complete(audioSnapshot());
      await frames(tester);
      expect(listens, 0);
    },
  );

  test('power reads never request permission or open settings without explicit action', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call.method);
      if (call.method == 'powerStatus') {
        return {
          'supported': true,
          'sdkInt': 36,
          'notificationsEnabled': false,
          'notificationPermissionGranted': false,
          'mediaNotificationExempt': true,
          'batteryOptimizationExempt': false,
          'backgroundRestricted': false,
        };
      }
      return true;
    });
    final bridge = LocalAudioBridge(isAndroid: true);
    final status = await bridge.readPowerStatus();
    expect(status.notificationPermissionGranted, isFalse);
    expect(calls, ['powerStatus']);
    expect(await bridge.openBatterySettings(), isTrue);
    expect(await bridge.openNotificationSettings(), isTrue);
    expect(calls, [
      'powerStatus',
      'openBatterySettings',
      'openNotificationSettings',
    ]);
  });
}
