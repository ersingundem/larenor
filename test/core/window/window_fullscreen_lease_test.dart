import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/window/window_policy_bridge.dart';
import 'package:larenor/core/window/window_policy_models.dart';

import 'window_policy_test.dart' show packet;

Map<String, Object?> fullscreenPacket({int displayRevision = 1}) => {
  ...packet(mode: 'panelRequested', displayRevision: displayRevision),
  'captionVisible': false,
  'imeVisible': false,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(WindowPolicyBridge.methodChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const display = (displayId: 0, displayRevision: 1, isExternalDisplay: false);
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'unique lease owns only its exact release and preserves observations',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'releaseFullscreen') return true;
        return {
          'schemaVersion': 1,
          'accepted': true,
          'revision': calls.length,
          'snapshot': fullscreenPacket(),
        };
      });
      final bridge = WindowPolicyBridge(isAndroid: true);
      final first = (await bridge.acquireFullscreen(display))!;
      final second = (await bridge.acquireFullscreen(display))!;
      expect(first.owner, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(second.owner, isNot(first.owner));
      expect(first.acquisition.requestedProfile, WindowProfile.adaptive);
      expect(first.acquisition.statusBarVisible, isTrue);
      expect(first.acquisition.lockTaskState, WindowLockTaskState.unknown);
      expect(await bridge.releaseFullscreen(first), isTrue);
      expect(calls.last.method, 'releaseFullscreen');
      expect(calls.last.arguments, {'owner': first.owner, 'revision': 1});
      expect(calls.map((call) => call.method), isNot(contains('setProfile')));
    },
  );

  test('unsupported, external and invalid identities do not write', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    expect(
      await WindowPolicyBridge(isAndroid: false).acquireFullscreen(display),
      isNull,
    );
    final bridge = WindowPolicyBridge(isAndroid: true);
    for (final next in [
      (displayId: 4, displayRevision: 1, isExternalDisplay: true),
      (displayId: -1, displayRevision: 1, isExternalDisplay: false),
      (displayId: 0, displayRevision: 0, isExternalDisplay: false),
    ]) {
      expect(await bridge.acquireFullscreen(next), isNull);
    }
    expect(calls, isEmpty);
  });

  test('denied lease is not interpreted as observed fullscreen', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {
        'schemaVersion': 1,
        'accepted': false,
        'revision': null,
        'snapshot': packet(),
      };
    });
    expect(
      await WindowPolicyBridge(isAndroid: true).acquireFullscreen(display),
      isNull,
    );
    expect(calls.map((call) => call.method), ['acquireFullscreen']);
  });

  test(
    'malformed or drifted grant cleans only its unique request owner',
    () async {
      for (final malformed in [
        {
          'schemaVersion': 1,
          'accepted': true,
          'revision': 1,
          'snapshot': packet(),
        },
        {
          'schemaVersion': 1,
          'accepted': true,
          'revision': 1,
          'snapshot': packet(mode: 'panelRequested', displayRevision: 2),
        },
        {
          'schemaVersion': 1,
          'accepted': false,
          'revision': 1,
          'snapshot': packet(),
        },
        {
          'schemaVersion': 1,
          'accepted': true,
          'revision': 0,
          'snapshot': packet(mode: 'panelRequested'),
        },
        {'private': 'fixture-private-error'},
      ]) {
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'cancelFullscreen' ? true : malformed;
        });
        expect(
          await WindowPolicyBridge(isAndroid: true).acquireFullscreen(display),
          isNull,
        );
        expect(calls.map((call) => call.method), [
          'acquireFullscreen',
          'cancelFullscreen',
        ]);
        final owner = (calls.first.arguments as Map)['owner'];
        expect(calls.last.arguments, {'owner': owner});
      }
    },
  );

  test(
    'platform errors are closed and exact cleanup does not change profile',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'cancelFullscreen') return false;
        throw PlatformException(
          code: 'unavailable',
          message: 'private-window-error',
        );
      });
      expect(
        await WindowPolicyBridge(isAndroid: true).acquireFullscreen(display),
        isNull,
      );
      expect(calls.map((call) => call.method), [
        'acquireFullscreen',
        'cancelFullscreen',
      ]);
    },
  );
}
