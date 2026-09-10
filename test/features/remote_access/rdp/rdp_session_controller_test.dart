import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';
import 'package:larenor/features/remote_access/rdp/rdp_engine.dart';
import 'package:larenor/features/remote_access/rdp/rdp_models.dart';
import 'package:larenor/features/remote_access/rdp/rdp_security_store.dart';
import 'package:larenor/features/remote_access/rdp/rdp_session_controller.dart';

import 'rdp_models_test.dart' show fixture, profile;

class Trust implements RdpTrustStore {
  RdpCertificatePin? pin;
  bool checked = false;
  @override
  Future<void> checkProfile(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw const RdpFailure('retired');
    checked = true;
  }

  @override
  Future<RdpCertificatePin?> readPin(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw const RdpFailure('retired');
    return pin;
  }

  @override
  Future<void> trust(
    RemoteProfile profile,
    RdpCertificatePin value, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw const RdpFailure('retired');
    pin = value;
  }
}

class Channel implements RdpChannel {
  int closes = 0;
  final pointers = <RdpPointerEvent>[];
  final keys = <RdpKeyEvent>[];
  final displays = <RdpDisplaySpec>[];
  final doneValue = Completer<void>();
  @override
  Future<void> get done => doneValue.future;
  @override
  void close() {
    closes++;
    if (!doneValue.isCompleted) doneValue.complete();
  }

  @override
  void pointer(RdpPointerEvent event) => pointers.add(event);
  @override
  void key(RdpKeyEvent event) => keys.add(event);
  @override
  void resize(RdpDisplaySpec display) => displays.add(display);
}

class Engine implements RdpEngine {
  Engine({this.available = true, this.requiresNla = true});
  final bool available, requiresNla;
  final channel = Channel();
  int inspections = 0, opens = 0, closes = 0;
  String? passwordSeen;
  Completer<RdpPeerSecurity>? delayed;
  @override
  Future<RdpCapabilities> capabilities({
    required bool Function() isCurrent,
  }) async => RdpCapabilities.fromJson(
    fixture()[available ? 'availableCapabilities' : 'unavailableCapabilities'],
  );
  @override
  Future<RdpPeerSecurity> inspect(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) {
    inspections++;
    return delayed?.future ??
        Future.value(
          RdpPeerSecurity(
            tls: true,
            requiresNla: requiresNla,
            certificate: RdpCertificatePin.fromJson(fixture()['certificate']),
          ),
        );
  }

  @override
  Future<RdpChannel> open(
    RdpSessionRequest request, {
    required String? nlaPassword,
    required bool Function() isCurrent,
  }) async {
    opens++;
    passwordSeen = nlaPassword;
    return channel;
  }

  @override
  void close() => closes++;
}

RdpSessionController controller(
  Engine engine,
  Trust trust,
  bool Function() current,
) => RdpSessionController(
  profile: profile,
  trust: trust,
  engineFactory: () => engine,
  isCurrent: current,
  display: const RdpDisplaySpec(
    width: 2560,
    height: 1600,
    dpi: 220,
    externalDisplay: true,
  ),
);

Future<void> flush() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class Vault implements RdpCredentialVault {
  RdpCredential? value;
  int reads = 0, writes = 0;
  @override
  Future<RdpCredential?> readCredential(RemoteProfile profile, {required bool Function() isCurrent}) async {
    reads++;
    if (!isCurrent()) throw const RdpFailure('retired');
    return value;
  }
  @override
  Future<void> saveCredential(RemoteProfile profile, RdpCredential credential, {required bool Function() isCurrent}) async {
    writes++;
    if (!isCurrent()) throw const RdpFailure('retired');
    value = credential;
  }
  @override
  Future<void> deleteCredential(RemoteProfile profile, {required bool Function() isCurrent}) async {
    value = null;
  }
}

void main() {
  test('unavailable engine is explicit and never opens a transport', () async {
    final engine = Engine(available: false),
        c = controller(engine, Trust(), () => true);
    await c.connect();
    expect(c.phase, RdpSessionPhase.unsupported);
    expect(engine.inspections, 0);
    expect(engine.opens, 0);
    c.dispose();
  });

  test('first pin and NLA are separate explicit states', () async {
    final engine = Engine(),
        trust = Trust(),
        c = controller(engine, trust, () => true);
    final opening = c.connect();
    await flush();
    expect(c.phase, RdpSessionPhase.certificate);
    expect(c.pendingCertificate, isNotNull);
    await c.trustCertificate();
    await flush();
    expect(c.phase, RdpSessionPhase.nlaRequired);
    expect(engine.opens, 0);
    await c.authenticate('one-time-password');
    await opening;
    expect(c.phase, RdpSessionPhase.connected);
    expect(engine.passwordSeen, 'one-time-password');
    expect(c.hasSensitiveInput, isFalse);
    c.dispose();
  });

  test('changed certificate closes without retry or replay', () async {
    final trust = Trust()
      ..pin = const RdpCertificatePin(
        algorithm: 'spki-sha256',
        fingerprint: 'SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
      );
    final engine = Engine(), c = controller(engine, trust, () => true);
    await c.connect();
    expect(c.phase, RdpSessionPhase.failed);
    expect(c.error, 'certificate_changed');
    expect(engine.opens, 0);
    await c.connect();
    expect(engine.inspections, 1);
    c.dispose();
  });

  test('focus or PIN retirement wipes input and closes exactly once', () async {
    var current = true;
    final trust = Trust()
      ..pin = RdpCertificatePin.fromJson(fixture()['certificate']);
    final engine = Engine(requiresNla: false),
        c = controller(engine, trust, () => current);
    await c.connect();
    expect(c.phase, RdpSessionPhase.connected);
    c.pointer(const RdpPointerEvent(x: .5, y: .5, buttons: 0));
    c.key(const RdpKeyEvent(physicalKey: 42, down: true));
    current = false;
    c.synchronize();
    expect(c.phase, RdpSessionPhase.closed);
    expect(engine.channel.closes, 1);
    expect(engine.channel.pointers, hasLength(1));
    expect(engine.channel.keys, hasLength(1));
    c.pointer(const RdpPointerEvent(x: .6, y: .6, buttons: 0));
    expect(engine.channel.pointers, hasLength(1));
    c.dispose();
  });

  test('late inspection after sign-out cannot publish or open', () async {
    var current = true;
    final engine = Engine()..delayed = Completer();
    final c = controller(engine, Trust(), () => current);
    final opening = c.connect();
    await flush();
    current = false;
    c.synchronize();
    engine.delayed!.complete(
      RdpPeerSecurity(
        tls: true,
        requiresNla: false,
        certificate: RdpCertificatePin.fromJson(fixture()['certificate']),
      ),
    );
    await opening;
    expect(c.phase, RdpSessionPhase.closed);
    expect(engine.opens, 0);
    c.dispose();
  });

  test('retirement completes a caller waiting on a stuck engine', () async {
    var current = true;
    final engine = Engine()..delayed = Completer();
    final c = controller(engine, Trust(), () => current);
    final opening = c.connect();
    await flush();
    current = false;
    c.synchronize();

    await expectLater(
      opening.timeout(const Duration(milliseconds: 50)),
      completes,
    );
    expect(c.phase, RdpSessionPhase.closed);
    c.dispose();
  });

  test('saved credential reuse and reconnect both require an explicit connect', () async {
    final trust = Trust()..pin = RdpCertificatePin.fromJson(fixture()['certificate']);
    final vault = Vault()..value = const RdpCredential(password: 'saved-secret');
    final engines = <Engine>[];
    final c = RdpSessionController(
      profile: profile,
      trust: trust,
      credentialVault: vault,
      engineFactory: () { final value = Engine(); engines.add(value); return value; },
      isCurrent: () => true,
      display: const RdpDisplaySpec(width: 1920, height: 1080, dpi: 180),
    );
    await c.connect();
    expect(c.phase, RdpSessionPhase.connected);
    expect(engines.single.passwordSeen, 'saved-secret');
    engines.single.channel.doneValue.completeError(StateError('lost'));
    await flush();
    expect(c.phase, RdpSessionPhase.failed);
    expect(engines, hasLength(1));
    await c.reconnect();
    expect(c.phase, RdpSessionPhase.connected);
    expect(engines, hasLength(2));
    c.dispose();
  });

  test('resize and clipboard policy reject stale or over-bounded input', () async {
    final trust = Trust()..pin = RdpCertificatePin.fromJson(fixture()['certificate']);
    final engine = Engine(requiresNla: false);
    final c = RdpSessionController(
      profile: profile,
      trust: trust,
      engineFactory: () => engine,
      isCurrent: () => true,
      display: const RdpDisplaySpec(width: 1920, height: 1080, dpi: 180),
      settings: const RdpProfileSettings(clipboardMode: RdpClipboardMode.disabled),
    );
    await c.connect();
    c.resize(const RdpDisplaySpec(width: 2560, height: 1440, dpi: 220, externalDisplay: true));
    c.resize(const RdpDisplaySpec(width: 9000, height: 1440, dpi: 220));
    expect(engine.channel.displays, hasLength(1));
    c.retire();
    c.resize(const RdpDisplaySpec(width: 1920, height: 1080, dpi: 180));
    expect(engine.channel.displays, hasLength(1));
    c.dispose();
  });
}
