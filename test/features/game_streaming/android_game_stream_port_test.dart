import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/game_streaming/data/android_game_stream_port.dart';
import 'package:larenor/features/game_streaming/data/android_game_stream_v2_port.dart';
import 'package:larenor/features/game_streaming/data/core_game_stream_api.dart';
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
  quality: const GameStreamQuality(
    widthPixels: 2560,
    heightPixels: 1600,
    framesPerSecond: 120,
    bitrateKbps: 24576,
    frameQueueDepth: 3,
    inputQueueDepth: 32,
    secureSurface: true,
  ),
);

Map<String, Object> receipt(GameStreamCommand value) => {
  'sessionId': value.sessionId,
  'commandId': value.commandId,
  'requestId': value.requestId,
  'intent': value.intent.name,
  'revisions': value.revisions.toJson(),
  'quality': value.quality.toJson(),
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

AndroidGameStreamAuthorityV2 authorityV2() => AndroidGameStreamAuthorityV2(
  clientInstanceId: '0' * 32,
  coreId: 'a' * 32,
  homeId: 'b' * 32,
  accountId: 'c' * 32,
  familyId: 'd' * 32,
  accountRevision: 2,
  pinRevision: 3,
  pinConfigured: true,
  pinUnlocked: true,
  routeRevision: 4,
  lifecycleRevision: 5,
  idleRevision: 6,
  interactionRevision: 7,
);

Map<String, Object> selectedQualityV2() => {
  'codec': 'h264',
  'codecId': codecId,
  'codecRevision': 14,
  'displayId': 1,
  'displayRevision': 13,
  'networkId': networkId,
  'networkRevision': 15,
  'policyId': policyId,
  'policyRevision': 16,
  'widthPixels': 1920,
  'heightPixels': 1080,
  'framesPerSecond': 60,
  'bitrateKbps': 20000,
  'frameQueueDepth': 2,
  'inputQueueDepth': 1,
  'secureSurface': true,
};

CoreGameStreamSession coreSessionV2() => CoreGameStreamSession.fromJson({
  'schemaVersion': 2,
  'id': sessionId,
  'hostId': hostId,
  'appId': appId,
  'revision': 1,
  'state': 'open',
  'expiresAt': 1800000000.0,
  'coreAuthority': {
    'accountRevision': 2,
    'hostRevision': 10,
    'pairingRevision': 11,
    'catalogRevision': 12,
    'appRevision': 13,
    'selectedQuality': selectedQualityV2(),
  },
  'selectedQuality': selectedQualityV2(),
  'clientAuthority': {
    'routeRevision': 4,
    'lifecycleRevision': 5,
    'displayRevision': 13,
    'networkRevision': 15,
    'policyRevision': 16,
  },
});

CoreGameStreamAuthorization coreAuthorizationV2() =>
    CoreGameStreamAuthorization(
      command: CoreGameStreamCommand.fromJson({
        'schemaVersion': 2,
        'id': commandId,
        'sessionId': sessionId,
        'intent': 'stream',
        'state': 'authorized',
        'result': null,
        'observationKind': null,
        'readbackRevision': null,
        'createdAt': 1799999990.0,
        'completedAt': null,
      }, sessionId: sessionId),
      dispatchGrant: 'a' * 32,
    );

CoreGameStreamHost coreHostV2() => CoreGameStreamHost.fromJson({
  'schemaVersion': 2,
  'id': hostId,
  'revision': 10,
  'pairingRevision': 11,
  'catalogRevision': 12,
  'name': 'Owned Sunshine fixture',
  'assurance': 'native_observed',
  'active': true,
  'codecs': ['h264'],
});

CoreGameStreamApp coreAppV2() => CoreGameStreamApp.fromJson({
  'schemaVersion': 2,
  'id': appId,
  'hostId': hostId,
  'revision': 13,
  'name': 'Desktop',
  'active': true,
}, hostId: hostId);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'v2 authority carries configured and freshly unlocked PIN assurance',
    () {
      expect(authorityV2().toJson(), {
        'clientInstanceId': '0' * 32,
        'coreId': 'a' * 32,
        'homeId': 'b' * 32,
        'accountId': 'c' * 32,
        'familyId': 'd' * 32,
        'accountRevision': 2,
        'pinRevision': 3,
        'pinConfigured': true,
        'pinUnlocked': true,
        'routeRevision': 4,
        'lifecycleRevision': 5,
        'idleRevision': 6,
        'interactionRevision': 7,
      });
    },
  );

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

  test('Moonlight handoff capability and launch receipt stay exact', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'capabilities') {
        return {
          'schemaVersion': 1,
          'availability': 'available',
          'engineRevision': 'moonlight-1202',
          'intents': <String>[],
          'maxInflight': 1,
          'provider': 'moonlight',
          'handoffOnly': true,
          'inputKinds': ['gamepad', 'keyboard', 'mouse', 'touch'],
        };
      }
      expect(call.method, 'openProvider');
      expect(call.arguments, isNull);
      return {
        'schemaVersion': 1,
        'provider': 'moonlight',
        'engineRevision': 'moonlight-1202',
        'handoffOnly': true,
      };
    });
    final port = AndroidGameStreamPort();
    final capabilities = await port.capabilities();
    expect(capabilities.available, isTrue);
    expect(capabilities.handoffOnly, isTrue);
    expect(capabilities.provider, 'moonlight');
    expect(capabilities.intents, isEmpty);
    expect(capabilities.inputKinds, {'touch', 'gamepad', 'keyboard', 'mouse'});
    final launch = await port.openProvider();
    expect(launch.provider, capabilities.provider);
    expect(launch.engineRevision, capabilities.engineRevision);
    expect(launch.handoffOnly, isTrue);
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

  test('v2 discovery and pairing carry no provider secret fields', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'beginPairingV2') {
        return {
          'schemaVersion': 2,
          'requestId': '1' * 32,
          'nativeBindingId': '2' * 32,
          'bindingRevision': 1,
          'engineRevision': 'moonlight-android-12.2-larenor-embed-v1',
          'provider': 'moonlight-nvhttp',
          'catalogRevision': 1,
          'catalogDigest': 'a' * 64,
          'candidates': [
            {
              'candidateId': '3' * 32,
              'revision': 1,
              'name': 'Owned Sunshine fixture',
              'powerState': 'awake',
              'pairState': 'notPaired',
            },
          ],
        };
      }
      if (call.method == 'pairHostV2') {
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        expect(args['pairingGrant'], '5' * 32);
        expect(args, isNot(contains('address')));
        expect(args, isNot(contains('pin')));
        expect(args, isNot(contains('certificate')));
        return {
          'schemaVersion': 2,
          'requestId': '4' * 32,
          'pairingId': '6' * 32,
          'state': 'paired',
          'nativeReceiptDigest': 'b' * 64,
          'observation': {
            'schemaVersion': 1,
            'receiptId': '7' * 32,
            'nativeBindingId': '2' * 32,
            'bindingRevision': 2,
            'engineRevision': 'moonlight-android-12.2-larenor-embed-v1',
            'provider': 'moonlight-nvhttp',
            'state': 'paired',
            'hostObservationId': '8' * 32,
            'name': 'Owned Sunshine fixture',
            'codecs': ['h264', 'hevc'],
            'catalogRevision': 2,
            'catalogDigest': 'c' * 64,
            'apps': [
              {'observationId': '9' * 32, 'revision': 1, 'name': 'Desktop'},
            ],
          },
        };
      }
      fail('unexpected ${call.method}');
    });
    final port = AndroidGameStreamV2Port();
    final discovery = await port.beginPairing(
      requestId: '1' * 32,
      authority: authorityV2(),
      timeoutMs: 15000,
    );
    final intent = CoreGameStreamPairingIntent.fromJson({
      'schemaVersion': 2,
      'id': '6' * 32,
      'revision': 1,
      'state': 'pending',
      'pairingGrant': '5' * 32,
      'expiresAt': 1788610200.0,
    });
    final paired = await port.pair(
      requestId: '4' * 32,
      authority: authorityV2(),
      discovery: discovery,
      intent: intent,
      candidate: discovery.candidates.single,
    );
    expect(paired.state, 'paired');
    expect(paired.observation?.apps.single.name, 'Desktop');
    expect(calls.map((call) => call.method), ['beginPairingV2', 'pairHostV2']);
  });

  test('v2 command terminal receipts preserve causal evidence rules', () async {
    var state = 'unknown';
    Object? readbackRevision;
    Object? nativeReceiptDigest;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'executeV2');
      final args = Map<Object?, Object?>.from(call.arguments as Map);
      final command = Map<Object?, Object?>.from(args['command']! as Map);
      return {
        'schemaVersion': 2,
        'requestId': requestId,
        'sessionId': sessionId,
        'commandId': command['id'],
        'state': state,
        'result': state == 'rejected' ? 'rejected' : 'unknown',
        'observationKind': state == 'rejected' ? 'nativeRejected' : 'unknown',
        'readbackRevision': readbackRevision,
        'nativeReceiptDigest': nativeReceiptDigest,
      };
    });
    final port = AndroidGameStreamV2Port();
    final session = coreSessionV2();
    final authorization = coreAuthorizationV2();

    final unknown = await port.executeV2(
      requestId: requestId,
      authority: authorityV2(),
      session: session,
      authorization: authorization,
    );
    expect(unknown.state, 'unknown');
    expect(unknown.readbackRevision, isNull);
    expect(unknown.nativeReceiptDigest, isNull);

    nativeReceiptDigest = 'b' * 64;
    await expectLater(
      port.executeV2(
        requestId: requestId,
        authority: authorityV2(),
        session: session,
        authorization: authorization,
      ),
      throwsA(
        isA<GameStreamException>().having(
          (failure) => failure.code,
          'code',
          'invalid_native_receipt',
        ),
      ),
    );

    state = 'rejected';
    readbackRevision = 17;
    final rejected = await port.executeV2(
      requestId: requestId,
      authority: authorityV2(),
      session: session,
      authorization: authorization,
    );
    expect(rejected.state, 'rejected');
    expect(rejected.readbackRevision, 17);
    expect(rejected.nativeReceiptDigest, 'b' * 64);
  });

  test('v2 stop carries the exact native lease safety closure', () async {
    late Map<Object?, Object?> executeArguments;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = Map<Object?, Object?>.from(call.arguments as Map);
      switch (call.method) {
        case 'resolveBindingV2':
          return {
            'schemaVersion': 2,
            'requestId': requestId,
            'nativeBindingId': '2' * 32,
            'bindingRevision': 3,
            'registrationRevision': 4,
            'hostId': hostId,
            'appId': appId,
            'engineRevision': 'moonlight-android-12.2-larenor-embed-v1',
          };
        case 'executeV2':
          executeArguments = args;
          final command = Map<Object?, Object?>.from(args['command']! as Map);
          return {
            'schemaVersion': 2,
            'requestId': requestId,
            'sessionId': sessionId,
            'commandId': command['id'],
            'state': 'native_observed',
            'result': 'stopped',
            'observationKind': 'connectionStopped',
            'readbackRevision': 18,
            'nativeReceiptDigest': 'c' * 64,
          };
        default:
          fail('unexpected native method ${call.method}');
      }
    });
    final port = AndroidGameStreamV2Port();
    final binding = await port.resolveBinding(
      requestId: requestId,
      authority: authorityV2(),
      host: CoreGameStreamHost.fromJson({
        'schemaVersion': 2,
        'id': hostId,
        'revision': 10,
        'pairingRevision': 11,
        'catalogRevision': 12,
        'name': 'Owned fixture',
        'assurance': 'native_observed',
        'active': true,
        'codecs': ['h264'],
      }),
      app: CoreGameStreamApp.fromJson({
        'schemaVersion': 2,
        'id': appId,
        'hostId': hostId,
        'revision': 13,
        'name': 'Desktop',
        'active': true,
      }, hostId: hostId),
    );
    final authorization = CoreGameStreamAuthorization(
      command: CoreGameStreamCommand.fromJson({
        'schemaVersion': 2,
        'id': commandId,
        'sessionId': sessionId,
        'intent': 'stop',
        'state': 'authorized',
        'result': null,
        'observationKind': null,
        'readbackRevision': null,
        'createdAt': 1788610200.0,
        'completedAt': null,
      }, sessionId: sessionId),
      dispatchGrant: 'a' * 32,
    );

    await port.executeV2(
      requestId: requestId,
      authority: authorityV2(),
      session: coreSessionV2(),
      authorization: authorization,
      safetyClosure: binding,
    );

    expect(executeArguments['safetyClosure'], {
      'nativeBindingId': '2' * 32,
      'bindingRevision': 3,
    });
  });

  test('v2 retirement requires the exact native session receipt', () async {
    Object? receipt = {
      'schemaVersion': 2,
      'sessionId': sessionId,
      'epoch': 1,
      'state': 'retired',
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'retire');
      expect(call.arguments, {'sessionId': sessionId, 'epoch': 1});
      if (receipt is PlatformException) throw receipt;
      return receipt;
    });
    final port = AndroidGameStreamV2Port();

    await port.retireV2(sessionId: sessionId, epoch: 1);

    receipt = null;
    await expectLater(
      port.retireV2(sessionId: sessionId, epoch: 1),
      throwsA(
        isA<GameStreamException>().having(
          (failure) => failure.code,
          'code',
          'invalid_native_receipt',
        ),
      ),
    );
    receipt = PlatformException(code: 'authority_changed');
    await expectLater(
      port.retireV2(sessionId: sessionId, epoch: 1),
      throwsA(isA<PlatformException>()),
    );
  });

  test(
    'v2 authority retirement accepts only the exact durable receipt',
    () async {
      late Map<Object?, Object?> arguments;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'retireAuthorityV2');
        arguments = Map<Object?, Object?>.from(call.arguments as Map);
        return {
          'schemaVersion': 2,
          'requestId': requestId,
          'authorityId': '1' * 32,
          'authorityEpoch': 9,
          'nativeBindingId': '2' * 32,
          'bindingRevision': 3,
          'state': 'retired',
        };
      });
      final port = AndroidGameStreamV2Port();

      final receipt = await port.retireAuthority(
        requestId: requestId,
        authority: authorityV2(),
      );

      expect(arguments['nativeBindingId'], isNull);
      expect(arguments['bindingRevision'], isNull);
      expect(receipt.authorityId, '1' * 32);
      expect(receipt.authorityEpoch, 9);
      expect(receipt.nativeBindingId, '2' * 32);
      expect(receipt.bindingRevision, 3);
      expect(
        () => port.retireAuthority(
          requestId: requestId,
          authority: authorityV2(),
          nativeBindingId: '2' * 32,
        ),
        throwsA(
          isA<GameStreamException>().having(
            (failure) => failure.code,
            'code',
            'invalid_native_binding',
          ),
        ),
      );
    },
  );

  test('v2 foreground coverage is exact and read only', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = Map<Object?, Object?>.from(call.arguments as Map);
      switch (call.method) {
        case 'resolveBindingV2':
          return {
            'schemaVersion': 2,
            'requestId': requestId,
            'nativeBindingId': '2' * 32,
            'bindingRevision': 3,
            'registrationRevision': 4,
            'hostId': hostId,
            'appId': appId,
            'engineRevision': 'moonlight-android-12.2-larenor-embed-v1',
          };
        case 'foregroundLeaseV2':
          expect(args['expectedBindingRevision'], 3);
          expect(args['expectedSessionRevision'], 1);
          return {
            'schemaVersion': 2,
            'requestId': requestId,
            'nativeBindingId': '2' * 32,
            'bindingRevision': 3,
            'sessionId': sessionId,
            'sessionRevision': 1,
            'owned': true,
            'state': 'game_visible',
          };
        case 'beginPairingV2':
          return {
            'schemaVersion': 2,
            'requestId': requestId,
            'nativeBindingId': '2' * 32,
            'bindingRevision': 3,
            'engineRevision': 'moonlight-android-12.2-larenor-embed-v1',
            'provider': 'moonlight-nvhttp',
            'catalogRevision': 1,
            'catalogDigest': 'c' * 64,
            'candidates': <Object>[],
          };
        case 'pairingPromptV2':
          expect(args['expectedBindingRevision'], 3);
          expect(args['expectedPairingRevision'], 1);
          return {
            'schemaVersion': 2,
            'requestId': requestId,
            'nativeBindingId': '2' * 32,
            'bindingRevision': 3,
            'pairingId': '6' * 32,
            'pairingRevision': 1,
            'owned': true,
            'state': 'pairing_prompt',
          };
        default:
          fail('unexpected ${call.method}');
      }
    });
    final port = AndroidGameStreamV2Port();
    final host = coreHostV2();
    final app = coreAppV2();
    final binding = await port.resolveBinding(
      requestId: requestId,
      authority: authorityV2(),
      host: host,
      app: app,
    );
    final game = await port.foregroundLease(
      requestId: requestId,
      authority: authorityV2(),
      binding: binding,
      session: coreSessionV2(),
    );
    expect(game.coverage, AndroidGameStreamForegroundCoverage.game);
    expect(game.state, 'game_visible');

    final discovery = await port.beginPairing(
      requestId: requestId,
      authority: authorityV2(),
      timeoutMs: 15000,
    );
    final prompt = await port.pairingPrompt(
      requestId: requestId,
      authority: authorityV2(),
      discovery: discovery,
      intent: CoreGameStreamPairingIntent.fromJson({
        'schemaVersion': 2,
        'id': '6' * 32,
        'revision': 1,
        'state': 'pending',
        'pairingGrant': '5' * 32,
        'expiresAt': 1788610200.0,
      }),
    );
    expect(prompt.coverage, AndroidGameStreamForegroundCoverage.pairingPrompt);
    expect(prompt.state, 'pairing_prompt');
  });

  test(
    'policy proposal uses observed display and decoder, never host ceilings',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'sessionCapabilitiesV2');
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        return {
          'schemaVersion': 2,
          'requestId': args['requestId'],
          'availability': 'unavailable',
          'reason': 'queuePolicyUnsupported',
          'display': {
            'displayId': 1,
            'displayRevision': 13,
            'attached': true,
            'widthPixels': 2560,
            'heightPixels': 1440,
            'densityDpi': 320,
            'secureSurface': true,
            'maxRefreshRate': 120,
          },
          'network': {
            'networkId': networkId,
            'networkRevision': 15,
            'reachability': 'local',
            'metered': false,
          },
          'decoders': [
            {
              'codecId': codecId,
              'codecRevision': 14,
              'codec': 'h264',
              'supported': true,
              'maxWidthPixels': 3840,
              'maxHeightPixels': 2160,
              'maxFramesPerSecond': 60,
            },
          ],
          'policy': null,
          'qualityOptions': <Object>[],
        };
      });
      final capabilities = await AndroidGameStreamV2Port().sessionCapabilities(
        requestId: requestId,
        authority: authorityV2(),
        host: coreHostV2(),
        app: coreAppV2(),
      );
      final draft = capabilities.explicitPolicyDraft(coreHostV2());
      expect(capabilities.available, isFalse);
      expect(draft, isNotNull);
      expect(draft!.allowedCodecs, ['h264']);
      expect(draft.maxWidth, 2560);
      expect(draft.maxHeight, 1440);
      expect(draft.maxFps, 60);
      expect(draft.frameQueueDepth, 2);
      expect(draft.inputQueueDepth, 1);
    },
  );
}
