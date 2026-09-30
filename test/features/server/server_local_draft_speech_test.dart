import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/automation_drafts/platform/local_draft_speech.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.ersingundem.larenor/local_speech');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    calls.clear();
  });

  test('probe and recognition accept only exact local receipts', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'probe' => <String, Object?>{
          'schemaVersion': 1,
          'onDeviceAvailable': true,
          'microphoneGranted': true,
        },
        'recognize' => <String, Object?>{
          'schemaVersion': 1,
          'onDevice': true,
          'text': 'ışığı aç',
        },
        _ => throw MissingPluginException(),
      };
    });
    const speech = LocalDraftSpeech();
    final capability = await speech.probe();
    expect(capability.available, isTrue);
    expect(capability.microphoneGranted, isTrue);
    expect(await speech.recognize('tr-TR'), 'ışığı aç');
    expect(calls.map((call) => call.method), ['probe', 'recognize']);
    expect(calls.first.arguments, isNull);
    expect(calls.last.arguments, {'locale': 'tr-TR'});
  });

  test(
    'readback sends bounded text and requires an on-device receipt',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return <String, Object?>{
          'schemaVersion': 1,
          'onDevice': true,
          'text': null,
        };
      });
      const speech = LocalDraftSpeech();
      await speech.speak('en-US', 'Lights are off');
      expect(calls.single.method, 'speak');
      expect(calls.single.arguments, {
        'locale': 'en-US',
        'text': 'Lights are off',
      });

      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {'schemaVersion': 1, 'onDevice': false, 'text': null},
      );
      await expectLater(
        speech.speak('en-US', 'Lights are off'),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('malformed or unsafe transcripts never cross the channel', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return <String, Object?>{
        'schemaVersion': 1,
        'onDevice': true,
        'text': 'safe',
      };
    });
    const speech = LocalDraftSpeech();
    for (final value in <String>['   ', 'hidden\u2066direction', 'x' * 257]) {
      await expectLater(
        speech.speak('en-US', value),
        throwsA(isA<FormatException>()),
      );
    }
    expect(calls, isEmpty);

    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {
        'schemaVersion': 1,
        'onDevice': true,
        'text': 'hidden\u2066direction',
      },
    );
    await expectLater(
      speech.recognize('en-US'),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'permission is explicit and cancellation hides provider errors',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'requestPermission') return false;
        if (call.method == 'cancel') {
          throw PlatformException(code: 'native_private_failure');
        }
        throw MissingPluginException();
      });
      const speech = LocalDraftSpeech();
      expect(await speech.requestPermission(), isFalse);
      await speech.cancel();
      expect(calls.map((call) => call.method), ['requestPermission', 'cancel']);
      expect(calls.first.arguments, isNull);
    },
  );
}
