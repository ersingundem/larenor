import 'dart:async';

import 'package:fake_async/fake_async.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart' show Uint8List;
import 'package:larenor/features/remote_access/data/remote_profiles.dart';
import 'package:larenor/features/remote_access/rdp/rdp_engine.dart';
import 'package:larenor/features/remote_access/rdp/rdp_models.dart';
import 'package:larenor/features/remote_access/rdp/rdp_security_store.dart';
import 'package:larenor/features/remote_access/rdp/rdp_session_controller.dart';

import 'rdp_models_test.dart' show fixture, profile, packagedCapabilities;

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

class Channel
    implements
        RdpFrameChannel,
        RdpNegotiatedInputChannel,
        RdpAudioPlaybackChannel,
        RdpMicrophoneCaptureChannel {
  Channel({this.supportsUnicodeInput = true});
  @override
  final bool supportsUnicodeInput;
  int audioReads = 0;
  Completer<RdpAudioObservation>? audioReply;
  @override
  Future<RdpAudioObservation> audioObservation() async {
    audioReads++;
    return audioReply?.future ??
        RdpAudioObservation.fromJson({
          'schemaVersion': 4,
          'requestId': 'fixture',
          'state': 'pending',
          'deviceOpen': false,
          'acceptedCount': 0,
          'completedCount': 0,
        }, requestId: 'fixture');
  }

  int microphoneReads = 0;
  Completer<RdpMicrophoneObservation>? microphoneReply;
  @override
  Future<RdpMicrophoneObservation> microphoneObservation() async {
    microphoneReads++;
    return microphoneReply?.future ??
        RdpMicrophoneObservation.fromJson({
          'schemaVersion': 4,
          'requestId': 'fixture',
          'state': 'pending',
          'deviceOpen': false,
          'capturedCount': 0,
          'acceptedCount': 0,
        }, requestId: 'fixture');
  }

  @override
  bool get supportsRelativePointer => true;
  @override
  Stream<RdpFrame> get frames => const Stream.empty();
  @override
  Future<bool> acknowledgeFrame(int sequence) async => true;
  final relatives = <RdpRelativePointerEvent>[];
  final wheels = <RdpWheelEvent>[];
  @override
  void relativePointer(RdpRelativePointerEvent event) => relatives.add(event);
  @override
  void wheel(RdpWheelEvent event) => wheels.add(event);
  int closes = 0;
  final pointers = <RdpPointerEvent>[];
  final keys = <RdpKeyEvent>[];
  final displays = <RdpDisplaySpec>[];
  final texts = <String>[];
  final clipboards = <String>[];
  bool clipboardAccepted = true;
  Completer<bool>? clipboardReply;
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
  void text(String value) => texts.add(value);
  @override
  void resize(RdpDisplaySpec display) => displays.add(display);
  @override
  Future<bool> sendClipboardText(String value) async {
    clipboards.add(value);
    return clipboardReply?.future ?? clipboardAccepted;
  }
}

class Engine implements RdpMicrophonePermissionEngine {
  Engine({
    this.available = true,
    this.supportsNla = true,
    this.clientRequiresNla = true,
    this.supportsClipboard = false,
    this.supportsAudio = false,
    this.supportsMicrophone = false,
    this.microphonePermissionGranted = true,
    this.negotiatedUnicodeInput = true,
  });
  final bool available, supportsNla, clientRequiresNla;
  final bool supportsClipboard;
  final bool supportsAudio;
  final bool supportsMicrophone;
  bool microphonePermissionGranted;
  final bool negotiatedUnicodeInput;
  late final channel = Channel(supportsUnicodeInput: negotiatedUnicodeInput);
  int inspections = 0, opens = 0, closes = 0;
  int microphonePermissionRequests = 0, microphonePermissionCancels = 0;
  Completer<bool>? microphonePermissionReply;
  String? passwordSeen;
  RdpSessionRequest? lastRequest;
  Completer<RdpCertificateProbe>? delayed;
  @override
  Future<RdpCapabilities> capabilities({
    required bool Function() isCurrent,
  }) async {
    final raw =
        fixture()[available
                ? 'availableCapabilities'
                : 'unavailableCapabilities']
            as Map<String, dynamic>;
    return RdpCapabilities.fromJson({
      ...raw,
      if (available)
        'security': {...raw['security'] as Map, 'nla': supportsNla},
      if (available)
        'channels': {
          ...(supportsClipboard
                  ? packagedCapabilities()['channels']
                  : raw['channels'])
              as Map,
          'audio': supportsAudio,
          'microphone': supportsMicrophone,
        },
    });
  }

  @override
  Future<RdpCertificateProbe> inspect(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) {
    inspections++;
    return delayed?.future ??
        Future.value(
          RdpCertificateProbe(
            tlsCertificateObserved: true,
            clientRequiresNla: clientRequiresNla,
            certificate: RdpCertificatePin.fromJson(fixture()['certificate']),
          ),
        );
  }

  @override
  Future<RdpChannel> open(
    RdpSessionRequest request, {
    required RdpCredential? credential,
    required bool Function() isCurrent,
  }) async {
    if (credential == null) throw const RdpFailure('invalid_credential');
    opens++;
    lastRequest = request;
    passwordSeen = credential.password;
    return channel;
  }

  @override
  void close() => closes++;

  @override
  Future<bool> requestMicrophonePermission({
    required bool Function() isCurrent,
  }) async {
    microphonePermissionRequests++;
    final result =
        await (microphonePermissionReply?.future ??
            Future.value(microphonePermissionGranted));
    if (!isCurrent()) throw const RdpFailure('retired');
    return result;
  }

  @override
  void cancelMicrophonePermission() => microphonePermissionCancels++;
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
    desktopScaleFactor: 220,
    externalDisplay: true,
  ),
);

Future<void> flush() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> connectWithPassword(RdpSessionController controller) async {
  final opening = controller.connect();
  await flush();
  expect(controller.phase, RdpSessionPhase.nlaRequired);
  await controller.authenticate('one-time-password');
  await opening;
}

class Vault implements RdpCredentialVault {
  RdpCredential? value;
  int reads = 0, writes = 0;
  @override
  Future<RdpCredential?> readCredential(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) async {
    reads++;
    if (!isCurrent()) throw const RdpFailure('retired');
    return value;
  }

  @override
  Future<void> saveCredential(
    RemoteProfile profile,
    RdpCredential credential, {
    required bool Function() isCurrent,
  }) async {
    writes++;
    if (!isCurrent()) throw const RdpFailure('retired');
    value = credential;
  }

  @override
  Future<void> deleteCredential(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) async {
    value = null;
  }
}

class DelayedVault extends Vault {
  final release = Completer<void>();

  @override
  Future<void> saveCredential(
    RemoteProfile profile,
    RdpCredential credential, {
    required bool Function() isCurrent,
  }) async {
    await release.future;
    await super.saveCredential(profile, credential, isCurrent: isCurrent);
  }
}

void main() {
  test('dispose with stuck audio leaves no polling or deadline timer', () {
    fakeAsync((clock) {
      final engine = Engine(supportsAudio: true);
      final reply = engine.channel.audioReply =
          Completer<RdpAudioObservation>();
      final c = RdpSessionController(
        profile: profile,
        trust: Trust()
          ..pin = RdpCertificatePin.fromJson(fixture()['certificate']),
        credentialVault: Vault()
          ..value = const RdpCredential(password: 'one-time'),
        engineFactory: () => engine,
        isCurrent: () => true,
        display: const RdpDisplaySpec(width: 640, height: 480),
        remoteAudio: true,
      );
      unawaited(c.connect());
      clock.flushMicrotasks();
      expect(c.phase, RdpSessionPhase.connected);
      expect(engine.channel.audioReads, 1);
      expect(clock.nonPeriodicTimerCount, 1);
      c.dispose();
      clock.flushMicrotasks();
      expect(clock.nonPeriodicTimerCount, 0);
      reply.complete(
        RdpAudioObservation.fromJson({
          'schemaVersion': 4,
          'requestId': 'fixture',
          'state': 'playing',
          'deviceOpen': true,
          'acceptedCount': 1,
          'completedCount': 1,
        }, requestId: 'fixture'),
      );
      clock.flushMicrotasks();
      expect(c.audioObservation, isNull);
      expect(clock.nonPeriodicTimerCount, 0);
    });
  });
  RdpSessionController audioController(
    Engine engine, {
    bool enabled = true,
    bool Function()? current,
  }) => RdpSessionController(
    profile: profile,
    trust: Trust()..pin = RdpCertificatePin.fromJson(fixture()['certificate']),
    engineFactory: () => engine,
    isCurrent: current ?? () => true,
    display: const RdpDisplaySpec(width: 640, height: 480),
    remoteAudio: enabled,
  );

  RdpSessionController microphoneController(
    Engine engine, {
    bool Function()? current,
    bool Function()? interactive,
    Vault? vault,
  }) => RdpSessionController(
    profile: profile,
    trust: Trust()..pin = RdpCertificatePin.fromJson(fixture()['certificate']),
    credentialVault:
        vault ?? (Vault()..value = const RdpCredential(password: 'one-time')),
    engineFactory: () => engine,
    isCurrent: current ?? () => true,
    isInteractive: interactive,
    display: const RdpDisplaySpec(width: 640, height: 480),
    settings: const RdpProfileSettings(microphone: true),
  );

  test('microphone is explicit, denied before inspect, and default off does no request', () async {
    final deniedEngine = Engine(
      supportsMicrophone: true,
      microphonePermissionGranted: false,
    );
    final denied = microphoneController(deniedEngine);
    await denied.connect();
    expect(denied.error, 'microphone_permission_denied');
    expect(deniedEngine.microphonePermissionRequests, 1);
    expect(deniedEngine.inspections, 0);
    expect(deniedEngine.opens, 0);
    denied.dispose();

    final offEngine = Engine(supportsMicrophone: true);
    final off = controller(
      offEngine,
      Trust()..pin = RdpCertificatePin.fromJson(fixture()['certificate']),
      () => true,
    );
    await connectWithPassword(off);
    expect(offEngine.microphonePermissionRequests, 0);
    expect(offEngine.lastRequest!.channels.microphone, isFalse);
    expect(offEngine.channel.microphoneReads, 0);
    off.dispose();
  });

  test(
    'permission focus loss waits for exact owner focus before native open',
    () async {
      var current = true, interactive = true;
      final engine = Engine(supportsMicrophone: true);
      final permission = engine.microphonePermissionReply = Completer<bool>();
      final c = microphoneController(
        engine,
        current: () => current,
        interactive: () => interactive,
      );
      final opening = c.connect();
      await flush();
      expect(c.microphonePermissionPending, isTrue);
      expect(engine.inspections, 0);
      interactive = false;
      permission.complete(true);
      await flush();
      expect(c.microphonePermissionPending, isTrue);
      expect(engine.inspections, 0);
      interactive = true;
      c.resumeMicrophonePermission();
      await opening;
      expect(c.phase, RdpSessionPhase.connected);
      expect(engine.inspections, 1);
      expect(engine.opens, 1);
      expect(engine.lastRequest!.channels.microphone, isTrue);
      expect(engine.channel.microphoneReads, 1);
      current = false;
      c.synchronize();
      expect(c.phase, RdpSessionPhase.closed);
      c.dispose();
    },
  );

  test(
    'retirement cancels permission and stale grant cannot open a successor',
    () async {
      var current = true;
      final engine = Engine(supportsMicrophone: true);
      final permission = engine.microphonePermissionReply = Completer<bool>();
      final c = microphoneController(engine, current: () => current);
      unawaited(c.connect());
      await flush();
      current = false;
      c.synchronize();
      permission.complete(true);
      await flush();
      expect(c.phase, RdpSessionPhase.closed);
      expect(engine.opens, 0);
      expect(engine.microphonePermissionCancels, greaterThanOrEqualTo(1));
      expect(c.microphoneObservation, isNull);
      c.dispose();
    },
  );

  test(
    'microphone observation is bounded and late result cannot revive dispose',
    () {
      fakeAsync((clock) {
        final engine = Engine(supportsMicrophone: true);
        final reply = engine.channel.microphoneReply =
            Completer<RdpMicrophoneObservation>();
        final c = microphoneController(engine);
        unawaited(c.connect());
        clock.flushMicrotasks();
        expect(c.phase, RdpSessionPhase.connected);
        expect(engine.channel.microphoneReads, 1);
        expect(clock.nonPeriodicTimerCount, 1);
        c.dispose();
        clock.flushMicrotasks();
        expect(clock.nonPeriodicTimerCount, 0);
        reply.complete(
          RdpMicrophoneObservation.fromJson({
            'schemaVersion': 4,
            'requestId': 'fixture',
            'state': 'sent',
            'deviceOpen': true,
            'capturedCount': 1,
            'acceptedCount': 1,
          }, requestId: 'fixture'),
        );
        clock.flushMicrotasks();
        expect(c.microphoneObservation, isNull);
        expect(clock.nonPeriodicTimerCount, 0);
      });
    },
  );

  test(
    'remote audio is opt-in and unsupported audio fails before inspection',
    () async {
      final unsupported = Engine();
      final denied = audioController(unsupported);
      await denied.connect();
      expect(denied.error, 'audio_unavailable');
      expect(unsupported.inspections, 0);
      expect(unsupported.opens, 0);
      denied.dispose();
      final enabled = Engine(supportsAudio: true);
      final c = audioController(enabled, enabled: false);
      await connectWithPassword(c);
      expect(enabled.lastRequest!.channels.audio, isFalse);
      expect(enabled.channel.audioReads, 0);
      c.dispose();
    },
  );

  test(
    'pending audio is not playback and late retired read cannot publish',
    () async {
      var current = true;
      final engine = Engine(supportsAudio: true);
      final pending = engine.channel.audioReply =
          Completer<RdpAudioObservation>();
      final c = audioController(engine, current: () => current);
      await connectWithPassword(c);
      expect(engine.lastRequest!.channels.audio, isTrue);
      expect(engine.channel.audioReads, 1);
      expect(c.audioObservation, isNull);
      current = false;
      pending.complete(
        RdpAudioObservation.fromJson({
          'schemaVersion': 4,
          'requestId': 'fixture',
          'state': 'playing',
          'deviceOpen': true,
          'acceptedCount': 1,
          'completedCount': 1,
        }, requestId: 'fixture'),
      );
      await flush();
      expect(c.phase, RdpSessionPhase.closed);
      expect(c.audioObservation, isNull);
      expect(engine.channel.audioReads, 1);
      c.dispose();
    },
  );

  test(
    'enabled audio keeps a pending baseline until native playback',
    () async {
      final engine = Engine(supportsAudio: true);
      final c = audioController(engine);
      await connectWithPassword(c);
      await flush();
      expect(c.audioObservation!.state, RdpAudioState.pending);
      expect(c.audioObservation!.hasCompletedPlayback, isFalse);
      c.dispose();
      await flush();
      expect(engine.channel.audioReads, 1);
    },
  );

  RdpSessionController clipboardController(
    RdpEngine Function() engineFactory, {
    bool Function()? current,
    RdpClipboardMode mode = RdpClipboardMode.clientToRemote,
  }) => RdpSessionController(
    profile: profile,
    trust: Trust()..pin = RdpCertificatePin.fromJson(fixture()['certificate']),
    engineFactory: engineFactory,
    isCurrent: current ?? () => true,
    display: const RdpDisplaySpec(
      width: 640,
      height: 480,
      desktopScaleFactor: 160,
    ),
    settings: RdpProfileSettings(clipboardMode: mode),
  );

  test(
    'clipboard requires opt-in before reading and rejects invalid text',
    () async {
      final offEngine = Engine();
      final off = clipboardController(
        () => offEngine,
        mode: RdpClipboardMode.disabled,
      );
      await connectWithPassword(off);
      var reads = 0;
      expect(
        await off.sendClipboardFrom(() async {
          reads++;
          return 'private';
        }),
        RdpClipboardSendResult.unavailable,
      );
      expect(reads, 0);
      expect(offEngine.channel.clipboards, isEmpty);
      off.dispose();

      final engine = Engine(supportsClipboard: true),
          c = clipboardController(() => engine);
      await connectWithPassword(c);
      for (final value in [null, '']) {
        expect(
          await c.sendClipboardFrom(() async => value),
          RdpClipboardSendResult.empty,
        );
      }
      for (final value in ['bad\u0000text', '\ud800', '😀' * 16385]) {
        expect(
          await c.sendClipboardFrom(() async => value),
          RdpClipboardSendResult.invalid,
        );
      }
      expect(engine.channel.clipboards, isEmpty);
      expect(
        await c.sendClipboardFrom(() async => 'İstanbul\n😀'),
        RdpClipboardSendResult.submitted,
      );
      expect(engine.channel.clipboards, ['İstanbul\n😀']);
      engine.channel.clipboardAccepted = false;
      expect(
        await c.sendClipboardFrom(() async => 'retry'),
        RdpClipboardSendResult.failed,
      );
      expect(
        await c.sendClipboardFrom(() async => throw StateError('private')),
        RdpClipboardSendResult.failed,
      );
      c.dispose();
    },
  );

  test(
    'pending clipboard read cannot enter an explicit successor connection',
    () async {
      final engines = <Engine>[];
      final c = clipboardController(() {
        final e = Engine(supportsClipboard: true);
        engines.add(e);
        return e;
      });
      await connectWithPassword(c);
      final read = Completer<String?>();
      final pending = c.sendClipboardFrom(() => read.future);
      c.disconnect();
      final reconnecting = c.reconnect();
      await flush();
      expect(c.phase, RdpSessionPhase.nlaRequired);
      await c.authenticate('new-one-time-password');
      await reconnecting;
      read.complete('old-session-private');
      expect(await pending, RdpClipboardSendResult.unavailable);
      expect(engines, hasLength(2));
      expect(engines.expand((e) => e.channel.clipboards), isEmpty);
      c.dispose();
    },
  );

  test(
    'authority retirement suppresses late read and submission success',
    () async {
      var current = true;
      final engine = Engine(supportsClipboard: true);
      final c = clipboardController(() => engine, current: () => current);
      await connectWithPassword(c);
      final read = Completer<String?>();
      final pending = c.sendClipboardFrom(() => read.future);
      current = false;
      read.complete('late');
      expect(await pending, RdpClipboardSendResult.unavailable);
      expect(engine.channel.clipboards, isEmpty);
      c.dispose();

      final successorEngine = Engine(supportsClipboard: true);
      final successor = clipboardController(() => successorEngine);
      await connectWithPassword(successor);
      successorEngine.channel.clipboardReply = Completer<bool>();
      final submitting = successor.sendClipboardFrom(() async => 'in-flight');
      await flush();
      successor.retire();
      successorEngine.channel.clipboardReply!.complete(true);
      expect(await submitting, RdpClipboardSendResult.unavailable);
      expect(successorEngine.channel.clipboards, ['in-flight']);
      successor.dispose();
    },
  );

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

  test(
    'certificate probe alone never opens an authenticated session',
    () async {
      final engine = Engine(), trust = Trust();
      final c = controller(engine, trust, () => true);
      final opening = c.connect();
      await flush();
      expect(c.phase, RdpSessionPhase.certificate);
      expect(engine.inspections, 1);
      expect(engine.opens, 0);
      c.retire();
      await opening;
      c.dispose();
    },
  );

  test(
    'missing mandatory NLA capability refuses before certificate probe',
    () async {
      final engine = Engine(supportsNla: false);
      final c = controller(engine, Trust(), () => true);
      await c.connect();
      expect(c.phase, RdpSessionPhase.failed);
      expect(c.error, 'nla_unsupported');
      expect(engine.inspections, 0);
      expect(engine.opens, 0);
      c.dispose();
    },
  );

  test('probe cannot weaken the fixed Client NLA policy', () async {
    final engine = Engine(clientRequiresNla: false);
    final c = controller(engine, Trust(), () => true);
    await c.connect();
    expect(c.phase, RdpSessionPhase.failed);
    expect(c.error, 'invalid_response');
    expect(engine.inspections, 1);
    expect(engine.opens, 0);
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
    final engine = Engine(), c = controller(engine, trust, () => current);
    await connectWithPassword(c);
    expect(c.phase, RdpSessionPhase.connected);
    final frame = RdpFrame(
      sequence: 1,
      width: 2560,
      height: 1600,
      stride: 10240,
      displayLayoutRevision: 1,
      bgra: Uint8List(0),
    );
    expect(await c.acknowledgeFrame(frame), isTrue);
    c.pointer(
      RdpPointerEvent(x: .5, y: .5, buttons: 0, geometry: frame.geometry),
    );
    c.key(const RdpKeyEvent(physicalKey: 0x00070004, down: true));
    current = false;
    c.synchronize();
    expect(c.phase, RdpSessionPhase.closed);
    expect(engine.channel.closes, 1);
    expect(engine.channel.pointers, hasLength(1));
    expect(engine.channel.keys, hasLength(1));
    c.pointer(
      RdpPointerEvent(x: .6, y: .6, buttons: 0, geometry: frame.geometry),
    );
    expect(engine.channel.pointers, hasLength(1));
    c.dispose();
  });

  test(
    'unsupported keyboard usage is ignored without closing the session',
    () async {
      final trust = Trust()
        ..pin = RdpCertificatePin.fromJson(fixture()['certificate']);
      final engine = Engine(), c = controller(engine, trust, () => true);
      await connectWithPassword(c);
      c.key(const RdpKeyEvent(physicalKey: 0x000c00e9, down: true));
      c.key(const RdpKeyEvent(physicalKey: 0x000700e0, down: true));
      expect(c.phase, RdpSessionPhase.connected);
      expect(engine.channel.closes, 0);
      expect(engine.channel.keys.map((event) => event.physicalKey), [
        0x000700e0,
      ]);
      c.dispose();
    },
  );

  test(
    'IME is enabled only by the authenticated session negotiation',
    () async {
      for (final negotiated in [false, true]) {
        final trust = Trust()
          ..pin = RdpCertificatePin.fromJson(fixture()['certificate']);
        final engine = Engine(negotiatedUnicodeInput: negotiated);
        final c = controller(engine, trust, () => true);
        await connectWithPassword(c);
        expect(c.supportsUnicodeInput, negotiated);
        c.text('İstanbul 😀');
        expect(engine.channel.texts, negotiated ? ['İstanbul 😀'] : isEmpty);
        c.dispose();
      }
    },
  );

  test('late inspection after sign-out cannot publish or open', () async {
    var current = true;
    final engine = Engine()..delayed = Completer();
    final c = controller(engine, Trust(), () => current);
    final opening = c.connect();
    await flush();
    current = false;
    c.synchronize();
    engine.delayed!.complete(
      RdpCertificateProbe(
        tlsCertificateObserved: true,
        clientRequiresNla: true,
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

  test(
    'saved credential reuse and reconnect both require an explicit connect',
    () async {
      final trust = Trust()
        ..pin = RdpCertificatePin.fromJson(fixture()['certificate']);
      final vault = Vault()
        ..value = const RdpCredential(password: 'saved-secret');
      final engines = <Engine>[];
      final c = RdpSessionController(
        profile: profile,
        trust: trust,
        credentialVault: vault,
        engineFactory: () {
          final value = Engine();
          engines.add(value);
          return value;
        },
        isCurrent: () => true,
        display: const RdpDisplaySpec(
          width: 1920,
          height: 1080,
          desktopScaleFactor: 180,
        ),
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
    },
  );

  test('resize and text input reject stale or over-bounded input', () async {
    final trust = Trust()
      ..pin = RdpCertificatePin.fromJson(fixture()['certificate']);
    final engine = Engine();
    final c = RdpSessionController(
      profile: profile,
      trust: trust,
      engineFactory: () => engine,
      isCurrent: () => true,
      display: const RdpDisplaySpec(
        width: 1920,
        height: 1080,
        desktopScaleFactor: 180,
      ),
      settings: const RdpProfileSettings(
        clipboardMode: RdpClipboardMode.disabled,
      ),
    );
    await connectWithPassword(c);
    c.resize(
      const RdpDisplaySpec(
        width: 2560,
        height: 1440,
        desktopScaleFactor: 220,
        externalDisplay: true,
      ),
    );
    c.resize(
      const RdpDisplaySpec(width: 9000, height: 1440, desktopScaleFactor: 220),
    );
    expect(engine.channel.displays, hasLength(1));
    c.text('İstanbul');
    c.text('');
    c.text('bad\u0000text');
    c.text('😀' * 1025);
    c.text('\ud800');
    expect(engine.channel.texts, ['İstanbul']);
    c.retire();
    c.resize(
      const RdpDisplaySpec(width: 1920, height: 1080, desktopScaleFactor: 180),
    );
    c.text('late');
    expect(engine.channel.displays, hasLength(1));
    expect(engine.channel.texts, ['İstanbul']);
    c.dispose();
  });

  test(
    'remembering NLA and gateway secrets is explicit and lifecycle-bound',
    () async {
      var current = true;
      final trust = Trust()
        ..pin = RdpCertificatePin.fromJson(fixture()['certificate']);
      final vault = DelayedVault();
      final engine = Engine();
      final c = RdpSessionController(
        profile: profile,
        trust: trust,
        credentialVault: vault,
        engineFactory: () => engine,
        isCurrent: () => current,
        display: const RdpDisplaySpec(
          width: 1920,
          height: 1080,
          desktopScaleFactor: 180,
        ),
        settings: const RdpProfileSettings(
          gatewayHost: 'gateway.home.arpa',
          gatewayUsername: 'gateway-user',
        ),
      );
      final opening = c.connect();
      await flush();
      expect(c.phase, RdpSessionPhase.nlaRequired);
      final auth = c.authenticate(
        'rdp-secret',
        gatewayPassword: 'gateway-secret',
        remember: true,
      );
      current = false;
      c.synchronize();
      vault.release.complete();
      await auth;
      await opening;
      expect(vault.value, isNull);
      expect(engine.opens, 0);
      c.dispose();
    },
  );
  test('controller admits only acknowledged current geometry and clears it on density resize', () async {
    final trust = Trust()
      ..pin = RdpCertificatePin.fromJson(fixture()['certificate']);
    final engine = Engine(), c = controller(engine, trust, () => true);
    await connectWithPassword(c);
    RdpFrame frame(int sequence, int revision) => RdpFrame(
      sequence: sequence,
      width: 2560,
      height: 1600,
      stride: 10240,
      displayLayoutRevision: revision,
      bgra: Uint8List(0),
    );
    final first = frame(1, 1);
    c.pointer(
      RdpPointerEvent(x: .5, y: .5, buttons: 0, geometry: first.geometry),
    );
    expect(engine.channel.pointers, isEmpty);
    expect(await c.acknowledgeFrame(first), isTrue);
    c.pointer(
      RdpPointerEvent(x: .5, y: .5, buttons: 0, geometry: first.geometry),
    );
    expect(engine.channel.pointers, hasLength(1));
    c.resize(
      const RdpDisplaySpec(
        width: 2560,
        height: 1600,
        desktopScaleFactor: 200,
        deviceScaleFactor: 180,
        externalDisplay: true,
      ),
    );
    expect(c.canSendPointer, isFalse);
    expect(await c.acknowledgeFrame(frame(2, 1)), isTrue);
    c.relativePointer(
      RdpRelativePointerEvent(
        deltaX: 1,
        deltaY: 2,
        buttons: 0,
        geometry: first.geometry,
      ),
    );
    expect(engine.channel.relatives, isEmpty);
    final current = frame(3, 2);
    expect(await c.acknowledgeFrame(current), isTrue);
    c.relativePointer(
      RdpRelativePointerEvent(
        deltaX: -1,
        deltaY: 2,
        buttons: 0,
        geometry: current.geometry,
      ),
    );
    c.wheel(RdpWheelEvent(wheelDelta: 120, geometry: current.geometry));
    expect(engine.channel.relatives, hasLength(1));
    expect(engine.channel.wheels, hasLength(1));
    c.dispose();
  });
}
