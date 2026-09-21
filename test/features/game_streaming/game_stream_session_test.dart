import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/game_streaming/domain/game_stream_session.dart';

const account = '11111111111111111111111111111111';
const hostId = '22222222222222222222222222222222';
const appId = '33333333333333333333333333333333';
const codecId = '44444444444444444444444444444444';
const networkId = '55555555555555555555555555555555';
const policyId = '66666666666666666666666666666666';

GameStreamAuthority authority({
  int accountRevision = 2,
  int routeRevision = 7,
  int lifecycleRevision = 11,
  int idleRevision = 13,
  bool pinUnlocked = true,
  bool foreground = true,
  bool routeVisible = true,
  bool interactionActive = true,
  bool idle = false,
  Duration idleFor = Duration.zero,
}) => GameStreamAuthority(
  accountId: account,
  accountRevision: accountRevision,
  pinRevision: 5,
  routeRevision: routeRevision,
  lifecycleRevision: lifecycleRevision,
  idleRevision: idleRevision,
  interactionRevision: 17,
  pinUnlocked: pinUnlocked,
  foreground: foreground,
  routeVisible: routeVisible,
  interactionActive: interactionActive,
  idle: idle,
  idleFor: idleFor,
);

GameStreamHost host({
  int revision = 3,
  HostPowerState power = HostPowerState.asleep,
}) => GameStreamHost(
  hostId: hostId,
  hostRevision: revision,
  pairingRevision: 4,
  paired: true,
  powerState: power,
);

GameStreamApp app({int revision = 6}) => GameStreamApp(
  appId: appId,
  appRevision: revision,
  hostId: hostId,
  hostRevision: 3,
  launchable: true,
);

GameStreamDisplay display({
  int revision = 8,
  bool attached = true,
  bool secureSurface = true,
}) => GameStreamDisplay(
  displayId: 0,
  displayRevision: revision,
  attached: attached,
  widthPixels: 2560,
  heightPixels: 1600,
  densityDpi: 280,
  secureSurface: secureSurface,
);

GameStreamCodec codec({int revision = 9}) => GameStreamCodec(
  codecId: codecId,
  codecRevision: revision,
  codec: GameVideoCodec.hevc,
  supported: true,
  maxWidthPixels: 3840,
  maxHeightPixels: 2160,
  maxFramesPerSecond: 120,
);

GameStreamNetwork network({int revision = 10, bool metered = false}) =>
    GameStreamNetwork(
      networkId: networkId,
      networkRevision: revision,
      reachability: NetworkReachability.local,
      metered: metered,
    );

GameStreamPolicy policy({int revision = 12, bool allowMetered = false}) =>
    GameStreamPolicy(
      policyId: policyId,
      policyRevision: revision,
      allowedCodecIds: const {codecId},
      allowMetered: allowMetered,
      requirePin: true,
      active: true,
      maximumIdle: const Duration(minutes: 5),
      maximumSession: const Duration(hours: 4),
    );

final class FakeGameStreamPort implements GameStreamPort {
  final calls = <GameStreamCommand>[];
  final retirements = <GameStreamRetirement>[];
  final handles = <Object>[];
  Completer<GameStreamNativeReceipt>? pending;
  bool loseAck = false;
  bool mismatch = false;

  @override
  Future<GameStreamNativeReceipt> execute(
    GameStreamCommand command,
    Object credentialHandle,
  ) async {
    calls.add(command);
    handles.add(credentialHandle);
    if (pending case final completer?) return completer.future;
    if (loseAck) throw TimeoutException('private pairing token');
    return receiptFor(command, mismatch: mismatch);
  }

  @override
  Future<void> retire(GameStreamRetirement retirement) async {
    retirements.add(retirement);
  }
}

GameStreamNativeReceipt receiptFor(
  GameStreamCommand command, {
  bool mismatch = false,
}) => GameStreamNativeReceipt(
  sessionId: command.sessionId,
  commandId: mismatch ? 'f' * 32 : command.commandId,
  requestId: command.requestId,
  intent: command.intent,
  revisions: command.revisions,
  quality: command.quality,
  accepted: true,
  observedState: switch (command.intent) {
    GameStreamIntent.wake => NativeStreamState.hostAwake,
    GameStreamIntent.launch => NativeStreamState.appRunning,
    GameStreamIntent.stream => NativeStreamState.streaming,
    GameStreamIntent.stop => NativeStreamState.stopped,
  },
  readbackRevision: 20 + command.intent.index,
);

final class Harness {
  Harness({HostPowerState power = HostPowerState.asleep, DateTime? now})
    : currentAuthority = authority(),
      currentHost = host(power: power),
      currentApp = app(),
      currentDisplay = display(),
      currentCodec = codec(),
      currentNetwork = network(),
      currentPolicy = policy(),
      accountOwner = Object(),
      routeOwner = Object(),
      credentialHandle = Object() {
    clock = now ?? DateTime.utc(2026, 9, 21, 12);
    coordinator = GameStreamSessionCoordinator(
      authorityResolver: () => currentAuthority,
      accountOwnerResolver: () => accountOwner,
      routeOwnerResolver: () => routeOwner,
      hostResolver: () => currentHost,
      appResolver: () => currentApp,
      displayResolver: () => currentDisplay,
      codecResolver: () => currentCodec,
      networkResolver: () => currentNetwork,
      policyResolver: () => currentPolicy,
      port: port,
      now: () => clock,
    );
  }

  GameStreamAuthority currentAuthority;
  GameStreamHost currentHost;
  GameStreamApp currentApp;
  GameStreamDisplay currentDisplay;
  GameStreamCodec currentCodec;
  GameStreamNetwork currentNetwork;
  GameStreamPolicy currentPolicy;
  final Object accountOwner;
  final Object routeOwner;
  final Object credentialHandle;
  late DateTime clock;
  final FakeGameStreamPort port = FakeGameStreamPort();
  late final GameStreamSessionCoordinator coordinator;

  GameStreamSessionState open() => coordinator.open(
    authority: currentAuthority,
    accountOwner: accountOwner,
    routeOwner: routeOwner,
    host: currentHost,
    app: currentApp,
    display: currentDisplay,
    codec: currentCodec,
    network: currentNetwork,
    policy: currentPolicy,
    credentialHandle: credentialHandle,
  );
}

void main() {
  test('open binds exact revisions and exposes a secret-free public state', () {
    final harness = Harness();
    final state = harness.open();
    expect(state.phase, GameStreamPhase.created);
    expect(
      state.revisions,
      GameStreamRevisions.fromSnapshots(
        host: harness.currentHost,
        app: harness.currentApp,
        display: harness.currentDisplay,
        codec: harness.currentCodec,
        network: harness.currentNetwork,
        policy: harness.currentPolicy,
      ),
    );
    expect(state.toDiagnostics().keys.toSet(), {
      'phase',
      'hostRevision',
      'appRevision',
      'displayRevision',
      'codecRevision',
      'networkRevision',
      'policyRevision',
      'outcomeUnknown',
    });
    final output = '${state.toDiagnostics()} $state ${harness.coordinator}';
    for (final secret in ['pairing', 'token', 'password', 'secret.internal']) {
      expect(output.toLowerCase(), isNot(contains(secret)));
    }
    expect(harness.port.calls, isEmpty);
  });

  test('PIN route lifecycle idle and every snapshot revision fail closed', () {
    for (final mutation in <void Function(Harness)>[
      (h) => h.currentAuthority = authority(pinUnlocked: false),
      (h) => h.currentAuthority = authority(routeVisible: false),
      (h) => h.currentAuthority = authority(foreground: false),
      (h) => h.currentAuthority = authority(interactionActive: false),
      (h) => h.currentAuthority = authority(idle: true),
      (h) => h.currentAuthority = authority(accountRevision: 3),
      (h) => h.currentAuthority = GameStreamAuthority(
        accountId: account,
        accountRevision: 2,
        pinRevision: 6,
        routeRevision: 7,
        lifecycleRevision: 11,
        idleRevision: 13,
        interactionRevision: 17,
        pinUnlocked: true,
        foreground: true,
        routeVisible: true,
        interactionActive: true,
        idle: false,
      ),
      (h) => h.currentAuthority = authority(routeRevision: 8),
      (h) => h.currentAuthority = authority(lifecycleRevision: 12),
      (h) => h.currentAuthority = authority(idleRevision: 14),
      (h) => h.currentHost = host(revision: 4),
      (h) => h.currentApp = app(revision: 7),
      (h) => h.currentDisplay = display(revision: 9),
      (h) => h.currentCodec = codec(revision: 10),
      (h) => h.currentNetwork = network(revision: 11),
      (h) => h.currentPolicy = policy(revision: 13),
    ]) {
      final harness = Harness();
      final capturedAuthority = harness.currentAuthority;
      final capturedHost = harness.currentHost;
      final capturedApp = harness.currentApp;
      final capturedDisplay = harness.currentDisplay;
      final capturedCodec = harness.currentCodec;
      final capturedNetwork = harness.currentNetwork;
      final capturedPolicy = harness.currentPolicy;
      mutation(harness);
      expect(
        () => harness.coordinator.open(
          authority: capturedAuthority,
          accountOwner: harness.accountOwner,
          routeOwner: harness.routeOwner,
          host: capturedHost,
          app: capturedApp,
          display: capturedDisplay,
          codec: capturedCodec,
          network: capturedNetwork,
          policy: capturedPolicy,
          credentialHandle: harness.credentialHandle,
        ),
        throwsA(isA<GameStreamException>()),
      );
      expect(harness.port.calls, isEmpty);
    }
  });

  test(
    'protected display and bounded low-latency quality reach native only',
    () async {
      final insecure = Harness()
        ..currentDisplay = display(secureSurface: false);
      expect(insecure.open, throwsA(isA<GameStreamException>()));

      final harness = Harness();
      harness.open();
      await harness.coordinator.dispatch(
        intent: GameStreamIntent.wake,
        requestId: 'a' * 32,
      );
      final quality = harness.port.calls.single.quality;
      expect(quality.secureSurface, isTrue);
      expect(quality.frameQueueDepth, 3);
      expect(quality.inputQueueDepth, 32);
      expect(quality.framesPerSecond, 120);
      expect(quality.bitrateKbps, inInclusiveRange(2000, 100000));
    },
  );

  test('current PIN lifecycle route and idle denial cannot mint a session', () {
    for (final denied in [
      authority(pinUnlocked: false),
      authority(foreground: false),
      authority(routeVisible: false),
      authority(interactionActive: false),
      authority(idle: true),
      authority(idleFor: const Duration(minutes: 6)),
    ]) {
      final harness = Harness()..currentAuthority = denied;
      expect(
        harness.open,
        throwsA(
          isA<GameStreamException>().having(
            (error) => error.code,
            'code',
            'authority_denied',
          ),
        ),
      );
      expect(harness.port.calls, isEmpty);
    }
  });

  test(
    'maximum session expiry retires without sending another intent',
    () async {
      final harness = Harness();
      harness.open();
      harness.clock = harness.clock.add(
        const Duration(hours: 4, microseconds: 1),
      );

      final state = await harness.coordinator.reconcile();
      expect(state.phase, GameStreamPhase.retired);
      expect(harness.port.calls, isEmpty);
      expect(
        harness.port.retirements.single.reason,
        GameStreamRetirementReason.sessionExpired,
      );
    },
  );

  test('wake launch stream stop are ordered exact and idempotent', () async {
    final harness = Harness();
    harness.open();
    const ids = [
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      'cccccccccccccccccccccccccccccccc',
      'dddddddddddddddddddddddddddddddd',
    ];
    final intents = GameStreamIntent.values;
    final phases = [
      GameStreamPhase.ready,
      GameStreamPhase.launched,
      GameStreamPhase.streaming,
      GameStreamPhase.stopped,
    ];
    for (var index = 0; index < intents.length; index++) {
      final first = await harness.coordinator.dispatch(
        intent: intents[index],
        requestId: ids[index],
      );
      final duplicate = await harness.coordinator.dispatch(
        intent: intents[index],
        requestId: ids[index],
      );
      expect(first, duplicate);
      expect(first.status, GameStreamReceiptStatus.verified);
      expect(harness.coordinator.state.phase, phases[index]);
    }
    expect(harness.port.calls.map((value) => value.intent), intents);
    expect(
      harness.port.handles.every(
        (value) => identical(value, harness.credentialHandle),
      ),
      isTrue,
    );
  });

  test('lost acknowledgement is unknown and never replayed', () async {
    final harness = Harness()..port.loseAck = true;
    harness.open();
    const request = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final first = await harness.coordinator.dispatch(
      intent: GameStreamIntent.wake,
      requestId: request,
    );
    final duplicate = await harness.coordinator.dispatch(
      intent: GameStreamIntent.wake,
      requestId: request,
    );
    expect(first, duplicate);
    expect(first.status, GameStreamReceiptStatus.unknown);
    expect(harness.coordinator.state.phase, GameStreamPhase.outcomeUnknown);
    expect(harness.port.calls, hasLength(1));
    expect(
      () => harness.coordinator.dispatch(
        intent: GameStreamIntent.wake,
        requestId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      ),
      throwsA(isA<GameStreamException>()),
    );
    expect(harness.port.calls, hasLength(1));
  });

  test(
    'detach retires pending operation and late callback cannot revive it',
    () async {
      final harness = Harness();
      harness.port.pending = Completer();
      harness.open();
      final pending = harness.coordinator.dispatch(
        intent: GameStreamIntent.wake,
        requestId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      final duplicate = harness.coordinator.dispatch(
        intent: GameStreamIntent.wake,
        requestId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      expect(identical(pending, duplicate), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(harness.port.calls, hasLength(1));
      final command = harness.port.calls.single;
      harness.currentDisplay = display(revision: 9, attached: false);
      await harness.coordinator.reconcile();
      expect(harness.coordinator.state.phase, GameStreamPhase.retired);
      expect(harness.port.retirements, hasLength(1));
      final receipt = await pending;
      expect(receipt.status, GameStreamReceiptStatus.unknown);
      harness.port.pending!.complete(receiptFor(command));
      await Future<void>.delayed(Duration.zero);
      expect(harness.coordinator.state.phase, GameStreamPhase.retired);
    },
  );

  test(
    'authority loss while callback is pending retires the session',
    () async {
      final harness = Harness();
      harness.port.pending = Completer();
      harness.open();
      final pending = harness.coordinator.dispatch(
        intent: GameStreamIntent.wake,
        requestId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      await Future<void>.delayed(Duration.zero);
      final command = harness.port.calls.single;
      harness.currentAuthority = authority(
        routeVisible: false,
        routeRevision: 8,
      );
      harness.port.pending!.complete(receiptFor(command));

      final receipt = await pending;
      expect(receipt.status, GameStreamReceiptStatus.unknown);
      expect(harness.coordinator.state.phase, GameStreamPhase.retired);
      expect(harness.port.retirements, hasLength(1));
    },
  );

  test(
    'mismatched callback is unknown and public command logs stay redacted',
    () async {
      final harness = Harness()..port.mismatch = true;
      harness.open();
      final receipt = await harness.coordinator.dispatch(
        intent: GameStreamIntent.wake,
        requestId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      expect(receipt.status, GameStreamReceiptStatus.unknown);
      expect(harness.coordinator.state.phase, GameStreamPhase.outcomeUnknown);
      final command = harness.port.calls.single;
      expect(command.toString(), 'GameStreamCommand(wake, redacted)');
      expect(command.toJson().keys, isNot(contains('token')));
      expect(command.toJson().keys, isNot(contains('pairingKey')));
    },
  );
}
