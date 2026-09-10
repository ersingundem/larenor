import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';
import 'package:larenor/features/remote_access/ssh/ssh_security_store.dart';
import 'package:larenor/features/remote_access/ssh/ssh_tunnel_controller.dart';
import 'package:larenor/features/remote_access/ssh/ssh_tunnel_engine.dart';
import 'package:larenor/features/remote_access/ssh/ssh_tunnel_models.dart';

import '../remote_profiles_test.dart' show profile;
import 'ssh_session_controller_test.dart' show Security, hostPin;

class TunnelSecurity extends Security {
  SshTunnelProfile? tunnel;
  @override
  Future<SshTunnelProfile?> readTunnel(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) async => isCurrent() ? tunnel : throw const SshFailure('retired');
  @override
  Future<void> saveTunnel(
    RemoteProfile profile,
    SshTunnelProfile value, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw const SshFailure('retired');
    tunnel = value;
  }
}

class TunnelHandle implements SshTunnelHandle {
  final complete = Completer<void>();
  bool closed = false;
  @override
  String get localAddress => '127.0.0.1';
  @override
  int get localPort => 8088;
  @override
  Future<void> get done => complete.future;
  @override
  void close() {
    closed = true;
    if (!complete.isCompleted) complete.complete();
  }
}

class TunnelEngine implements SshTunnelEngine {
  final handle = TunnelHandle();
  int starts = 0;
  bool closed = false;
  SshTunnelProfile? received;
  SshHostPin presented = hostPin;
  @override
  Future<SshTunnelHandle> start(
    RemoteProfile profile,
    SshCredential credential,
    SshTunnelProfile tunnel, {
    required Future<bool> Function(SshHostPin pin) verifyHost,
    required bool Function() isCurrent,
  }) async {
    starts++;
    received = tunnel;
    if (!await verifyHost(presented)) throw const SshFailure('host_rejected');
    if (!isCurrent()) throw const SshFailure('retired');
    return handle;
  }

  @override
  void close() {
    closed = true;
    handle.close();
  }
}

void main() {
  test('profile validation fixes loopback bind and bounds every port', () {
    final value = SshTunnelProfile.parse(
      name: 'Jellyfin',
      localPort: '8088',
      targetHost: 'media.lan',
      targetPort: '8096',
    );
    expect(value.bindAddress, '127.0.0.1');
    expect(value.localPort, 8088);
    expect(value.targetHost, 'media.lan');
    for (final local in ['0', '80', '65536', 'word']) {
      expect(
        () => SshTunnelProfile.parse(
          name: 'Bad',
          localPort: local,
          targetHost: 'host.lan',
          targetPort: '443',
        ),
        throwsA(isA<SshFailure>()),
      );
    }
  });

  late TunnelSecurity security;
  late TunnelEngine engine;
  late SshTunnelController controller;
  bool current = true;
  setUp(() {
    security = TunnelSecurity()..pin = hostPin;
    engine = TunnelEngine();
    current = true;
    controller = SshTunnelController(
      profile: profile(),
      store: security,
      engineFactory: () => engine,
      isCurrent: () => current,
    );
  });
  tearDown(() => controller.dispose());

  test('load and save never start a connection', () async {
    await controller.load();
    final value = SshTunnelProfile.parse(
      name: 'Media',
      localPort: '8088',
      targetHost: '127.0.0.1',
      targetPort: '8096',
    );
    await controller.save(value);
    expect(security.tunnel, same(value));
    expect(engine.starts, 0);
  });

  test(
    'explicit start reuses credential and pin once and exposes active bind',
    () async {
      security.tunnel = SshTunnelProfile.parse(
        name: 'Media',
        localPort: '8088',
        targetHost: '127.0.0.1',
        targetPort: '8096',
      );
      await controller.load();
      await controller.start();
      expect(engine.starts, 1);
      expect(controller.phase, SshTunnelPhase.active);
      expect(controller.localEndpoint, '127.0.0.1:8088');
    },
  );

  test('changed host key fails closed before active state', () async {
    security.tunnel = SshTunnelProfile.parse(
      name: 'Media',
      localPort: '8088',
      targetHost: '127.0.0.1',
      targetPort: '8096',
    );
    engine.presented = const SshHostPin(
      'ssh-rsa',
      'SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
    );
    await controller.load();
    await controller.start();
    expect(controller.error, 'host_changed');
    expect(engine.closed, isTrue);
    expect(controller.phase, SshTunnelPhase.failed);
  });

  test(
    'cancel and owner retirement close once with no automatic restart',
    () async {
      security.tunnel = SshTunnelProfile.parse(
        name: 'Media',
        localPort: '8088',
        targetHost: '127.0.0.1',
        targetPort: '8096',
      );
      await controller.load();
      await controller.start();
      controller.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(engine.closed, isTrue);
      expect(engine.starts, 1);
      expect(controller.phase, SshTunnelPhase.ready);
      current = false;
      controller.retire();
      expect(engine.starts, 1);
    },
  );
}
