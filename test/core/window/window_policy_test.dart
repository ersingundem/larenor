import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/window/window_policy_bridge.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/core/window/window_policy_providers.dart';

Map<String, Object?> packet({String mode = 'adaptive'}) => {
  'supported': true,
  'requestedProfile': 'adaptive',
  'effectiveMode': mode,
  'reason': 'none',
  'isResumed': true,
  'hasWindowFocus': true,
  'isMultiWindow': false,
  'isPictureInPicture': false,
  'isExternalDisplay': false,
  'captionVisible': null,
  'imeVisible': null,
  'statusBarVisible': true,
  'navigationBarVisible': true,
  'lockTaskPermitted': null,
  'lockTaskState': 'unknown',
};

const methods = MethodChannel(WindowPolicyBridge.methodChannelName);
const events = MethodChannel(WindowPolicyBridge.eventChannelName);
const codec = StandardMethodCodec();

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump();
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

  test('strict packet preserves unknown evidence and never infers kiosk', () {
    final result = WindowPolicySnapshot.fromChannel(
      packet(mode: 'panelRequested'),
    );
    expect(result.effectiveMode, WindowEffectiveMode.panelRequested);
    expect(result.statusBarVisible, isTrue);
    expect(result.captionVisible, isNull);
    expect(result.lockTaskState, WindowLockTaskState.unknown);
    for (final invalid in [
      null,
      {},
      {...packet(), 'isResumed': 'yes'},
      {...packet(), 'lockTaskState': 'permissionGranted'},
      {...packet(), 'captionVisible': 0},
      {...packet(), 'requestedProfile': 'kiosk'},
      {...packet(), 'private': 'fixture-secret'},
    ]) {
      expect(
        () => WindowPolicySnapshot.fromChannel(invalid),
        throwsFormatException,
      );
    }
  });

  test(
    'other platforms and missing plugin stay unsupported without writes',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call.method);
        throw MissingPluginException();
      });
      final other = WindowPolicyBridge(isAndroid: false);
      expect((await other.snapshot()).supported, isFalse);
      expect((await other.setProfile(WindowProfile.panel)).supported, isFalse);
      expect((await other.changes.first).supported, isFalse);
      expect(calls, isEmpty);
      final missing = WindowPolicyBridge(isAndroid: true);
      expect(
        (await missing.changes.first).reason,
        WindowRestrictionReason.unsupported,
      );
      expect(calls, ['snapshot']);
    },
  );

  test(
    'typed profile method is separate from readonly snapshot and errors redact',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        return packet();
      });
      final bridge = WindowPolicyBridge(isAndroid: true);
      await bridge.snapshot();
      await bridge.setProfile(WindowProfile.panel);
      expect(calls.map((call) => call.method), ['snapshot', 'setProfile']);
      expect(calls.first.arguments, isNull);
      expect(calls.last.arguments, {'profile': 'panel'});
      messenger.setMockMethodCallHandler(methods, (_) async {
        throw PlatformException(
          code: 'unknown',
          message: 'fixture-private-data',
        );
      });
      final failed = await bridge.setProfile(WindowProfile.adaptive);
      expect(failed.reason, WindowRestrictionReason.unknown);
      expect(failed.toString(), isNot(contains('private')));
      messenger.setMockMethodCallHandler(
        methods,
        (_) async => {'unsupported': 'secret'},
      );
      expect(
        (await bridge.snapshot()).effectiveMode,
        WindowEffectiveMode.unknown,
      );
    },
  );

  testWidgets(
    'provider shares events, retains owner, and cancels at container teardown',
    (tester) async {
      final calls = <String>[];
      final eventCalls = <String>[];
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call.method);
        return packet();
      });
      messenger.setMockMethodCallHandler(events, (call) async {
        eventCalls.add(call.method);
        return null;
      });
      final container = ProviderContainer(
        overrides: [
          windowPolicyBridgeProvider.overrideWithValue(
            WindowPolicyBridge(isAndroid: true),
          ),
        ],
      );
      addTearDown(container.dispose);
      final first = container.listen(windowPolicySnapshotProvider, (_, _) {});
      final second = container.listen(windowPolicySnapshotProvider, (_, _) {});
      await frames(tester);
      expect(calls, ['snapshot']);
      expect(eventCalls, ['listen']);
      await messenger.handlePlatformMessage(
        WindowPolicyBridge.eventChannelName,
        codec.encodeSuccessEnvelope({
          ...packet(),
          'effectiveMode': 'restricted',
          'reason': 'multiWindow',
        }),
        (_) {},
      );
      await frames(tester);
      expect(
        container.read(windowPolicySnapshotProvider).value?.reason,
        WindowRestrictionReason.multiWindow,
      );
      first.close();
      second.close();
      await frames(tester);
      expect(eventCalls, ['listen']);
      container.dispose();
      await frames(tester);
      expect(eventCalls, ['listen', 'cancel']);
      expect(calls, ['snapshot']);
    },
  );

  testWidgets(
    'late snapshot cannot install events after subscription cancellation',
    (tester) async {
      final waiting = Completer<Object?>();
      var listens = 0;
      messenger.setMockMethodCallHandler(methods, (_) => waiting.future);
      messenger.setMockMethodCallHandler(events, (_) async {
        listens++;
        return null;
      });
      final bridge = WindowPolicyBridge(isAndroid: true);
      final listener = bridge.changes.listen((_) {});
      unawaited(listener.cancel());
      waiting.complete(packet());
      await frames(tester);
      expect(listens, 0);
    },
  );

  testWidgets(
    'malformed events become unknown and valid recovery is still observed',
    (tester) async {
      messenger.setMockMethodCallHandler(methods, (_) async => packet());
      messenger.setMockMethodCallHandler(events, (_) async => null);
      final received = <WindowPolicySnapshot>[];
      final listener = WindowPolicyBridge(isAndroid: true).changes
          .listen(received.add);
      await frames(tester);
      await messenger.handlePlatformMessage(
        WindowPolicyBridge.eventChannelName,
        codec.encodeSuccessEnvelope({'unsafe': 'private'}),
        (_) {},
      );
      await frames(tester);
      expect(received.last.reason, WindowRestrictionReason.unknown);
      await messenger.handlePlatformMessage(
        WindowPolicyBridge.eventChannelName,
        codec.encodeSuccessEnvelope(packet()),
        (_) {},
      );
      await frames(tester);
      expect(received.last.effectiveMode, WindowEffectiveMode.adaptive);
      unawaited(listener.cancel());
      await frames(tester);
    },
  );
}
