import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/game_streaming/data/android_game_stream_port.dart';
import 'package:larenor/features/game_streaming/domain/game_stream_session.dart';
import 'package:larenor/features/game_streaming/presentation/game_stream_personal_session.dart';

const accountId = '11111111111111111111111111111111';
const hostId = '22222222222222222222222222222222';
const appId = '33333333333333333333333333333333';
const codecId = '44444444444444444444444444444444';
const networkId = '55555555555555555555555555555555';
const policyId = '66666666666666666666666666666666';
const credentialId = '77777777777777777777777777777777';

GameStreamAuthority authority({
  int accountRevision = 2,
  int routeRevision = 3,
  int lifecycleRevision = 4,
  bool foreground = true,
}) => GameStreamAuthority(
  accountId: accountId,
  accountRevision: accountRevision,
  pinRevision: 5,
  routeRevision: routeRevision,
  lifecycleRevision: lifecycleRevision,
  idleRevision: 6,
  interactionRevision: 7,
  pinUnlocked: true,
  foreground: foreground,
  routeVisible: true,
  interactionActive: true,
  idle: false,
);

final class _CoordinatorPort implements GameStreamPort {
  @override
  Future<GameStreamNativeReceipt> execute(
    GameStreamCommand command,
    Object credentialHandle,
  ) => throw UnimplementedError();

  @override
  Future<void> retire(GameStreamRetirement retirement) async {}
}

GameStreamSessionState openSession(
  GameStreamAuthority value,
  Object accountOwner,
  Object routeOwner,
) {
  final host = GameStreamHost(
    hostId: hostId,
    hostRevision: 8,
    pairingRevision: 9,
    paired: true,
    powerState: HostPowerState.awake,
  );
  final app = GameStreamApp(
    appId: appId,
    appRevision: 10,
    hostId: hostId,
    hostRevision: 8,
    launchable: true,
  );
  final display = GameStreamDisplay(
    displayId: 1,
    displayRevision: 11,
    attached: true,
    widthPixels: 2560,
    heightPixels: 1600,
    densityDpi: 280,
    secureSurface: true,
  );
  final codec = GameStreamCodec(
    codecId: codecId,
    codecRevision: 12,
    codec: GameVideoCodec.hevc,
    supported: true,
    maxWidthPixels: 3840,
    maxHeightPixels: 2160,
    maxFramesPerSecond: 60,
  );
  final network = GameStreamNetwork(
    networkId: networkId,
    networkRevision: 13,
    reachability: NetworkReachability.local,
    metered: false,
  );
  final policy = GameStreamPolicy(
    policyId: policyId,
    policyRevision: 14,
    allowedCodecIds: const {codecId},
    allowMetered: false,
    requirePin: true,
    active: true,
    maximumIdle: const Duration(minutes: 5),
    maximumSession: const Duration(hours: 4),
  );
  return GameStreamSessionCoordinator(
    authorityResolver: () => value,
    accountOwnerResolver: () => accountOwner,
    routeOwnerResolver: () => routeOwner,
    hostResolver: () => host,
    appResolver: () => app,
    displayResolver: () => display,
    codecResolver: () => codec,
    networkResolver: () => network,
    policyResolver: () => policy,
    port: _CoordinatorPort(),
  ).open(
    authority: value,
    accountOwner: accountOwner,
    routeOwner: routeOwner,
    host: host,
    app: app,
    display: display,
    codec: codec,
    network: network,
    policy: policy,
    credentialHandle: Object(),
  );
}

final class _BindingPort implements GameStreamNativeBindingPort {
  final bindings = <AndroidGameStreamBinding>[];
  final retired = <AndroidGameStreamBinding>[];
  Completer<void>? pending;

  @override
  Future<void> bind(AndroidGameStreamBinding binding) async {
    bindings.add(binding);
    if (pending case final wait?) await wait.future;
  }

  @override
  Future<void> retire(GameStreamRetirement retirement) async {}

  @override
  Future<void> retireBinding(AndroidGameStreamBinding binding) async {
    retired.add(binding);
  }
}

void main() {
  late Object accountOwner;
  late Object routeOwner;
  late GameStreamAuthority currentAuthority;
  late GameStreamSessionState currentSession;
  late bool gateCurrent;
  late bool routeCurrent;
  late _BindingPort port;
  late GameStreamPersonalSessionBinder binder;
  late AndroidGameStreamCredentialHandle credential;

  setUp(() {
    accountOwner = Object();
    routeOwner = Object();
    currentAuthority = authority();
    currentSession = openSession(currentAuthority, accountOwner, routeOwner);
    gateCurrent = true;
    routeCurrent = true;
    port = _BindingPort();
    credential = AndroidGameStreamCredentialHandle(credentialId);
    binder = GameStreamPersonalSessionBinder(
      port: port,
      accountOwnerResolver: () => accountOwner,
      routeOwnerResolver: () => routeOwner,
      authorityResolver: () => currentAuthority,
      sessionResolver: () => currentSession,
      gateCurrent: () => gateCurrent,
      routeCurrent: () => routeCurrent,
    );
  });

  test('exact personal authority becomes an exact native binding', () async {
    final epoch = await binder.bind(
      accountOwner: accountOwner,
      routeOwner: routeOwner,
      authority: currentAuthority,
      session: currentSession,
      credentialHandle: credential,
    );
    expect(epoch, 1);
    final binding = port.bindings.single;
    expect(binding.sessionId, currentSession.sessionId);
    expect(binding.accountRevision, 2);
    expect(binding.routeRevision, 3);
    expect(binding.lifecycleRevision, 4);
    expect(binding.idleRevision, 6);
    expect(binding.interactionRevision, 7);
    expect(binding.credentialHandle, same(credential));
    expect('$binding $credential', isNot(contains(credentialId)));
  });

  test(
    'wrong account route and foreground authority fail before native',
    () async {
      for (final attempt in <Future<int> Function()>[
        () => binder.bind(
          accountOwner: Object(),
          routeOwner: routeOwner,
          authority: currentAuthority,
          session: currentSession,
          credentialHandle: credential,
        ),
        () => binder.bind(
          accountOwner: accountOwner,
          routeOwner: Object(),
          authority: currentAuthority,
          session: currentSession,
          credentialHandle: credential,
        ),
      ]) {
        await expectLater(attempt(), throwsA(isA<GameStreamException>()));
      }
      currentAuthority = authority(foreground: false);
      await expectLater(
        binder.bind(
          accountOwner: accountOwner,
          routeOwner: routeOwner,
          authority: currentAuthority,
          session: currentSession,
          credentialHandle: credential,
        ),
        throwsA(isA<GameStreamException>()),
      );
      expect(port.bindings, isEmpty);
    },
  );

  test('late native bind is retired when route revision changes', () async {
    port.pending = Completer<void>();
    final operation = binder.bind(
      accountOwner: accountOwner,
      routeOwner: routeOwner,
      authority: currentAuthority,
      session: currentSession,
      credentialHandle: credential,
    );
    await Future<void>.delayed(Duration.zero);
    currentAuthority = authority(routeRevision: 9);
    port.pending!.complete();
    await expectLater(
      operation,
      throwsA(
        isA<GameStreamException>().having(
          (failure) => failure.code,
          'code',
          'stale_personal_session',
        ),
      ),
    );
    expect(port.retired, [port.bindings.single]);
  });

  test('explicit retirement targets the exact bound epoch once', () async {
    await binder.bind(
      accountOwner: accountOwner,
      routeOwner: routeOwner,
      authority: currentAuthority,
      session: currentSession,
      credentialHandle: credential,
    );
    await binder.retire();
    await binder.retire();
    expect(port.retired.length, 1);
    expect(port.retired.single.epoch, 1);
  });
}
