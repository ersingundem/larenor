import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/game_streaming/data/android_game_stream_port.dart';
import 'package:larenor/features/game_streaming/domain/game_stream_session.dart';

const channel = MethodChannel('com.ersingundem.larenor/game-stream-native');
const sessionId = '11111111111111111111111111111111';
const commandId = '22222222222222222222222222222222';
const requestId = '33333333333333333333333333333333';
const hostId = '44444444444444444444444444444444';
const appId = '55555555555555555555555555555555';
const codecId = '66666666666666666666666666666666';
const networkId = '77777777777777777777777777777777';
const policyId = '88888888888888888888888888888888';
const handleId = '99999999999999999999999999999999';

GameStreamRevisions revisions() => GameStreamRevisions.fromSnapshots(
  host: GameStreamHost(
    hostId: hostId,
    hostRevision: 10,
    pairingRevision: 11,
    paired: true,
    powerState: HostPowerState.awake,
  ),
  app: GameStreamApp(
    appId: appId,
    appRevision: 12,
    hostId: hostId,
    hostRevision: 10,
    launchable: true,
  ),
  display: GameStreamDisplay(
    displayId: 1,
    displayRevision: 13,
    attached: true,
    widthPixels: 1920,
    heightPixels: 1080,
    densityDpi: 220,
    secureSurface: true,
  ),
  codec: GameStreamCodec(
    codecId: codecId,
    codecRevision: 14,
    codec: GameVideoCodec.hevc,
    supported: true,
    maxWidthPixels: 3840,
    maxHeightPixels: 2160,
    maxFramesPerSecond: 60,
  ),
  network: GameStreamNetwork(
    networkId: networkId,
    networkRevision: 15,
    reachability: NetworkReachability.local,
    metered: false,
  ),
  policy: GameStreamPolicy(
    policyId: policyId,
    policyRevision: 16,
    allowedCodecIds: const {codecId},
    allowMetered: false,
    requirePin: true,
    active: true,
    maximumIdle: const Duration(minutes: 5),
    maximumSession: const Duration(hours: 4),
  ),
);

GameStreamCommand command() => GameStreamCommand(
  sessionId: sessionId,
  commandId: commandId,
  requestId: requestId,
  intent: GameStreamIntent.stream,
  hostId: hostId,
  appId: appId,
  displayId: 1,
  codecId: codecId,
  networkId: networkId,
  policyId: policyId,
  revisions: revisions(),
);

Map<String, Object> receipt(GameStreamCommand value) => {
  'sessionId': value.sessionId,
  'commandId': value.commandId,
  'requestId': value.requestId,
  'intent': value.intent.name,
  'revisions': value.revisions.toJson(),
  'accepted': true,
  'observedState': 'streaming',
  'readbackRevision': 17,
};

AndroidGameStreamBinding binding(
  AndroidGameStreamCredentialHandle handle, {
  int epoch = 7,
  int routeRevision = 3,
}) => AndroidGameStreamBinding(
  sessionId: sessionId,
  epoch: epoch,
  accountRevision: 2,
  routeRevision: routeRevision,
  lifecycleRevision: 4,
  idleRevision: 5,
  interactionRevision: 6,
  credentialHandle: handle,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('unavailable capability contract is explicit and bounded', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'capabilities');
      expect(call.arguments, isNull);
      return {
        'schemaVersion': 1,
        'availability': 'unavailable',
        'engineRevision': null,
        'intents': <String>[],
        'maxInflight': 1,
      };
    });
    final capabilities = await AndroidGameStreamPort().capabilities();
    expect(capabilities.available, isFalse);
    expect(capabilities.engineRevision, isNull);
    expect(capabilities.intents, isEmpty);
  });

  test(
    'bind passes one opaque handle and no credential-shaped fields',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      final handle = AndroidGameStreamCredentialHandle(handleId);
      final value = binding(handle);
      await AndroidGameStreamPort().bind(value);
      final payload = Map<Object?, Object?>.from(calls.single.arguments as Map);
      expect(payload['credentialHandle'], handleId);
      expect(payload.keys, isNot(contains('token')));
      expect(payload.keys, isNot(contains('password')));
      expect('$handle $value', isNot(contains(handleId)));
    },
  );

  test('exact native receipt is accepted and mismatch is rejected', () async {
    final handle = AndroidGameStreamCredentialHandle(handleId);
    var mismatch = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'bind') return null;
      if (call.method == 'execute') {
        final value = receipt(command());
        if (mismatch) value['requestId'] = 'a' * 32;
        return value;
      }
      fail('unexpected ${call.method}');
    });
    final port = AndroidGameStreamPort();
    await port.bind(binding(handle));
    final accepted = await port.execute(command(), handle);
    expect(accepted.observedState, NativeStreamState.streaming);
    mismatch = true;
    await expectLater(
      port.execute(command(), handle),
      throwsA(
        isA<GameStreamException>().having(
          (failure) => failure.code,
          'code',
          'invalid_native_receipt',
        ),
      ),
    );
  });

  test('route retirement revokes locally before a late callback', () async {
    final handle = AndroidGameStreamCredentialHandle(handleId);
    final pending = Completer<Object?>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'bind' || call.method == 'retire') return null;
      if (call.method == 'execute') return pending.future;
      fail('unexpected ${call.method}');
    });
    final port = AndroidGameStreamPort();
    await port.bind(binding(handle));
    final late = port.execute(command(), handle);
    await port.retire(
      const GameStreamRetirement(
        sessionId: sessionId,
        reason: GameStreamRetirementReason.authorityChanged,
      ),
    );
    pending.complete(receipt(command()));
    await expectLater(
      late,
      throwsA(
        isA<GameStreamException>().having(
          (failure) => failure.code,
          'code',
          'stale_native_callback',
        ),
      ),
    );
    await expectLater(
      port.execute(command(), handle),
      throwsA(isA<GameStreamException>()),
    );
  });

  test('credential identity and authority rebind fail closed', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    final handle = AndroidGameStreamCredentialHandle(handleId);
    final port = AndroidGameStreamPort();
    await port.bind(binding(handle));
    await expectLater(
      port.execute(command(), AndroidGameStreamCredentialHandle(handleId)),
      throwsA(isA<GameStreamException>()),
    );
    await port.bind(binding(handle, epoch: 8, routeRevision: 4));
    expect(calls, ['bind', 'retire', 'bind']);
  });

  test(
    'late overlapping bind cannot replace the newest local authority',
    () async {
      final handle = AndroidGameStreamCredentialHandle(handleId);
      final first = Completer<Object?>();
      final second = Completer<Object?>();
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'retire') return null;
        if (call.method == 'execute') return receipt(command());
        final value = Map<Object?, Object?>.from(call.arguments as Map);
        return value['epoch'] == 7 ? first.future : second.future;
      });
      final port = AndroidGameStreamPort();
      final older = port.bind(binding(handle));
      await Future<void>.delayed(Duration.zero);
      final newer = port.bind(binding(handle, epoch: 8, routeRevision: 4));
      second.complete(null);
      await newer;
      first.complete(null);
      await expectLater(
        older,
        throwsA(
          isA<GameStreamException>().having(
            (failure) => failure.code,
            'code',
            'stale_native_callback',
          ),
        ),
      );
      expect(calls, ['bind', 'bind', 'retire']);
      expect(
        (await port.execute(command(), handle)).observedState,
        NativeStreamState.streaming,
      );
    },
  );
}
