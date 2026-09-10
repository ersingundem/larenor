import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';
import 'package:larenor/features/remote_access/vnc/vnc_engine.dart';
import 'package:larenor/features/remote_access/vnc/vnc_models.dart';
import 'package:larenor/features/remote_access/vnc/vnc_security_store.dart';
import 'package:larenor/features/remote_access/vnc/vnc_session_controller.dart';

import 'vnc_models_test.dart' show fixture, profile;

class Trust implements VncTrustStore {
  VncCertificatePin? pin;
  bool checked = false;

  @override
  Future<void> checkProfile(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw const VncFailure('retired');
    checked = true;
  }

  @override
  Future<VncCertificatePin?> readPin(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw const VncFailure('retired');
    return pin;
  }

  @override
  Future<void> trust(
    RemoteProfile profile,
    VncCertificatePin value, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw const VncFailure('retired');
    if (pin != null) throw const VncFailure('pin_exists');
    pin = value;
  }
}

class Channel implements VncChannel {
  int closes = 0;
  final pointers = <VncPointerEvent>[];
  final keys = <VncKeyEvent>[];
  final doneValue = Completer<void>();
  @override
  Future<void> get done => doneValue.future;
  @override
  void close() {
    closes++;
    if (!doneValue.isCompleted) doneValue.complete();
  }

  @override
  void pointer(VncPointerEvent event) => pointers.add(event);
  @override
  void key(VncKeyEvent event) => keys.add(event);
}

class Engine implements VncEngine {
  Engine({this.available = true, this.plain = false});
  final bool available, plain;
  final channel = Channel();
  int negotiations = 0, opens = 0, closes = 0;
  String? requestText, secretText;
  Completer<RfbNegotiation>? delayed;

  @override
  Future<VncCapabilities> capabilities({
    required bool Function() isCurrent,
  }) async => VncCapabilities.fromJson(
    fixture()[available ? 'availableCapabilities' : 'unavailableCapabilities'],
  );

  @override
  Future<RfbNegotiation> negotiate(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) {
    negotiations++;
    return delayed?.future ??
        Future.value(
          RfbNegotiation.fromJson(
            fixture()[plain ? 'plainNegotiation' : 'secureNegotiation'],
          ),
        );
  }

  @override
  Future<VncChannel> open(
    VncSessionRequest request, {
    VncSecretLease? password,
    required bool Function() isCurrent,
  }) async {
    opens++;
    requestText = request.toString();
    secretText = password?.toString();
    password?.dispose();
    return channel;
  }

  @override
  void close() => closes++;
}

VncSessionController controller(
  VncEngine engine,
  Trust trust,
  bool Function() current, {
  Duration timeout = const Duration(seconds: 45),
}) => VncSessionController(
  profile: profile,
  trust: trust,
  engineFactory: () => engine,
  isCurrent: current,
  display: const VncDisplaySpec(
    width: 2560,
    height: 1600,
    dpi: 220,
    externalDisplay: true,
  ),
  connectTimeout: timeout,
);

Future<void> flush() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'unsupported engine is explicit and never negotiates or opens',
    () async {
      final engine = Engine(available: false);
      final value = controller(engine, Trust(), () => true);
      await value.connect();
      expect(value.phase, VncSessionPhase.unsupported);
      expect(engine.negotiations, 0);
      expect(engine.opens, 0);
      value.dispose();
    },
  );

  test('plain VNC is rejected with no retry, replay, or open', () async {
    final engine = Engine(plain: true);
    final value = controller(engine, Trust(), () => true);
    await value.connect();
    expect(value.phase, VncSessionPhase.failed);
    expect(value.error, 'plain_vnc_rejected');
    expect(engine.opens, 0);
    await value.connect();
    expect(engine.negotiations, 1);
    value.dispose();
  });

  test('first pin and password are explicit one-time states', () async {
    const password = 'one-time-password';
    final engine = Engine(), trust = Trust();
    final value = controller(engine, trust, () => true);
    final opening = value.connect();
    await flush();
    expect(value.phase, VncSessionPhase.certificate);
    await value.trustCertificate();
    await flush();
    expect(value.phase, VncSessionPhase.passwordRequired);
    await value.authenticate(password);
    await opening;
    expect(value.phase, VncSessionPhase.connected);
    expect(engine.requestText, isNot(contains(password)));
    expect(engine.secretText, isNot(contains(password)));
    expect(value.hasSensitiveInput, isFalse);
    value.dispose();
  });

  test('changed certificate fails closed before password or open', () async {
    final trust = Trust()
      ..pin = const VncCertificatePin(
        algorithm: 'spki-sha256',
        fingerprint: 'SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
      );
    final engine = Engine(), value = controller(engine, trust, () => true);
    await value.connect();
    expect(value.phase, VncSessionPhase.failed);
    expect(value.error, 'certificate_changed');
    expect(engine.opens, 0);
    value.dispose();
  });

  test(
    'focus or PIN retirement closes exactly once and blocks input',
    () async {
      var current = true;
      final trust = Trust()
        ..pin = VncCertificatePin.fromJson(fixture()['certificate']);
      final engine = Engine(), value = controller(engine, trust, () => current);
      final opening = value.connect();
      await flush();
      await value.authenticate('temporary');
      await opening;
      expect(value.phase, VncSessionPhase.connected);
      value.pointer(const VncPointerEvent(x: .5, y: .5, buttons: 0));
      value.key(const VncKeyEvent(physicalKey: 42, down: true));
      current = false;
      value.synchronize();
      value.synchronize();
      expect(value.phase, VncSessionPhase.closed);
      expect(engine.channel.closes, 1);
      value.pointer(const VncPointerEvent(x: .6, y: .6, buttons: 0));
      expect(engine.channel.pointers, hasLength(1));
      expect(engine.channel.keys, hasLength(1));
      value.dispose();
    },
  );

  test('late negotiation after sign-out cannot publish or open', () async {
    var current = true;
    final engine = Engine()..delayed = Completer();
    final value = controller(engine, Trust(), () => current);
    final opening = value.connect();
    await flush();
    current = false;
    value.synchronize();
    engine.delayed!.complete(
      RfbNegotiation.fromJson(fixture()['secureNegotiation']),
    );
    await opening;
    expect(value.phase, VncSessionPhase.closed);
    expect(engine.opens, 0);
    value.dispose();
  });

  test('retirement completes caller waiting on a stuck engine', () async {
    var current = true;
    final engine = Engine()..delayed = Completer();
    final value = controller(engine, Trust(), () => current);
    final opening = value.connect();
    await flush();
    current = false;
    value.synchronize();
    await expectLater(
      opening.timeout(const Duration(milliseconds: 50)),
      completes,
    );
    value.dispose();
  });

  test('bounded connect times out once without retrying', () async {
    final engine = Engine()..delayed = Completer();
    final value = controller(
      engine,
      Trust(),
      () => true,
      timeout: const Duration(milliseconds: 10),
    );
    await value.connect();
    expect(value.phase, VncSessionPhase.failed);
    expect(value.error, 'timed_out');
    expect(engine.negotiations, 1);
    expect(engine.opens, 0);
    await value.connect();
    expect(engine.negotiations, 1);
    value.dispose();
  });
}
