import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';
import 'package:larenor/features/remote_access/rdp/rdp_models.dart';

Map<String, dynamic> fixture() =>
    jsonDecode(File('contracts/rdp-client.v4.json').readAsStringSync())
        as Map<String, dynamic>;

Map<String, dynamic> packagedCapabilities({
  bool ime = false,
  bool audio = false,
  List<String> clipboardModes = const ['disabled', 'clientToRemote'],
}) {
  final value = jsonDecode(
    jsonEncode(fixture()['availableCapabilities']),
  ) as Map<String, dynamic>;
  (value['input'] as Map<String, dynamic>)['ime'] = ime;
  value['channels'] = <String, Object?>{
    'clipboard': clipboardModes.any((value) => value != 'disabled'),
    'clipboardModes': clipboardModes,
    'audio': audio,
    'microphone': true,
    'files': false,
  };
  return value;
}

const profile = RemoteProfile(
  id: 'a0000000000000000000000000000001',
  name: 'Office PC',
  protocol: RemoteProtocol.rdp,
  host: 'desktop.home.arpa',
  port: 3389,
  username: 'ersin',
);

void main() {
  test('v4 fixture binds the exact microphone permission receipt', () {
    final request = fixture()['microphonePermissionRequest'] as Map;
    final granted = fixture()['microphonePermissionGranted'] as Map;
    expect(request.keys.toSet(), {'schemaVersion', 'requestId'});
    expect(granted.keys.toSet(), {'schemaVersion', 'requestId', 'granted'});
    expect(request['schemaVersion'], 4);
    expect(granted['schemaVersion'], 4);
    expect(granted['requestId'], request['requestId']);
    expect(granted['granted'], isTrue);
  });

  test(
    'microphone observation is exact, monotonic and not a remote effect',
    () {
      Map<String, Object?> packet({
        String state = 'pending',
        bool open = false,
        int captured = 0,
        int accepted = 0,
      }) => {
        'schemaVersion': 4,
        'requestId': 'fixture-request',
        'state': state,
        'deviceOpen': open,
        'capturedCount': captured,
        'acceptedCount': accepted,
      };
      RdpMicrophoneObservation parse(Object? value) =>
          RdpMicrophoneObservation.fromJson(
            value,
            requestId: 'fixture-request',
          );
      final pending = parse(packet());
      final opened = parse(packet(state: 'opened', open: true));
      final captured = parse(
        packet(state: 'captured', open: true, captured: 1),
      );
      final sent = parse(
        packet(state: 'sent', open: true, captured: 2, accepted: 1),
      );
      final closed = parse(packet(state: 'closed', captured: 2, accepted: 1));
      expect(opened.follows(pending), isTrue);
      expect(opened.follows(opened), isTrue);
      expect(captured.follows(pending), isTrue);
      expect(captured.hasSubmittedAudio, isFalse);
      expect(sent.follows(captured), isTrue);
      expect(sent.hasSubmittedAudio, isTrue);
      expect(closed.follows(sent), isTrue);
      expect(sent.follows(closed), isFalse);
      for (final value in [
        {...packet(), 'schemaVersion': 3},
        {...packet(), 'requestId': 'another-session'},
        {
          ...packet(),
          'rawAudio': [1],
        },
        packet(state: 'opened', open: true, captured: 1),
        packet(state: 'captured', open: true),
        packet(state: 'sent', open: true, captured: 1),
        packet(state: 'closed', open: true),
        packet(captured: 1, accepted: 2),
        packet(captured: 9007199254740992),
      ]) {
        expect(() => parse(value), throwsA(isA<RdpFailure>()));
      }
    },
  );

  test(
    'audio observation is exact, bounded and playback requires completion',
    () {
      Map<String, Object?> packet({
        String state = 'pending',
        bool open = false,
        int accepted = 0,
        int completed = 0,
      }) => {
        'schemaVersion': 4,
        'requestId': 'fixture-request',
        'state': state,
        'deviceOpen': open,
        'acceptedCount': accepted,
        'completedCount': completed,
      };
      RdpAudioObservation parse(Object? value) =>
          RdpAudioObservation.fromJson(value, requestId: 'fixture-request');
      final baseline = parse(packet());
      final accepted = parse(packet(state: 'playing', open: true, accepted: 1));
      final completed = parse(
        packet(state: 'playing', open: true, accepted: 1, completed: 1),
      );
      expect(accepted.follows(baseline), isTrue);
      expect(accepted.hasCompletedPlayback, isFalse);
      expect(completed.hasCompletedPlayback, isTrue);
      expect(accepted.follows(completed), isFalse);
      final closed = parse(packet(state: 'closed', accepted: 1, completed: 1));
      expect(closed.hasCompletedPlayback, isFalse);
      expect(closed.follows(completed), isTrue);
      expect(completed.follows(closed), isTrue);
      final failed = parse(packet(state: 'failed', accepted: 1, completed: 1));
      expect(completed.follows(failed), isFalse);
      for (final value in [
        {...packet(), 'schemaVersion': 2},
        {...packet(), 'requestId': 'another-session'},
        {
          ...packet(),
          'pcm': [0],
        },
        {...packet(), 'state': 'serverConfirmed'},
        {...packet(), 'deviceOpen': 1},
        packet(accepted: -1),
        packet(accepted: 9007199254740992),
        packet(completed: 1),
        packet(state: 'playing', open: true),
        packet(state: 'deviceOpen'),
        packet(state: 'closed', open: true),
        packet(accepted: 1),
      ]) {
        expect(() => parse(value), throwsA(isA<RdpFailure>()));
      }
    },
  );
  test(
    'clipboard text validates UTF-8 bytes without replacing invalid text',
    () {
      for (final value in [
        '',
        'bad\u0000text',
        '\ud800',
        '\udc00',
        '\ud800x',
        'x' * 65537,
        'İ' * 32769,
        '😀' * 16385,
      ]) {
        expect(validRdpClipboardText(value), isFalse);
      }
      for (final value in [
        'İstanbul\n\t😀',
        'x' * 65536,
        'İ' * 32768,
        '😀' * 16384,
      ]) {
        expect(validRdpClipboardText(value), isTrue);
      }
      expect(validRdpImeText('x' * 4096), isTrue);
      expect(validRdpImeText('x' * 4097), isFalse);
    },
  );

  test('keyboard accepts the bounded USB HID surface used by RDP', () {
    for (final usage in [
      0x00070004, // A
      0x0007001e, // 1
      0x00070038, // slash
      0x0007003a, // F1
      0x0007004c, // Delete
      0x00070054, // keypad divide
      0x000700e0, // left control
      0x000700e7, // right GUI
    ]) {
      expect(
        RdpKeyEvent(physicalKey: usage, down: true).supported,
        isTrue,
        reason: 'usage 0x${usage.toRadixString(16)}',
      );
    }
    for (final usage in [0, 0x00070000, 0x00070066, 0x000c00e9]) {
      expect(
        RdpKeyEvent(physicalKey: usage, down: true).supported,
        isFalse,
        reason: 'usage 0x${usage.toRadixString(16)}',
      );
    }
  });

  test('strict capabilities distinguish unavailable and secure RDP', () {
    final f = fixture();
    final available = RdpCapabilities.fromJson(f['availableCapabilities']);
    final unavailable = RdpCapabilities.fromJson(f['unavailableCapabilities']);
    expect(available.canConnect, isTrue);
    expect(available.supportsNla, isTrue);
    expect(available.supportsExternalDisplay, isTrue);
    expect(available.supportsIme, isTrue);
    expect(available.supportsMicrophone, isTrue);
    expect(unavailable.canConnect, isFalse);
    expect(unavailable.engineRevision, isNull);
    expect(
      () => RdpCapabilities.fromJson({
        ...f['availableCapabilities'] as Map,
        'futureCapability': true,
      }),
      throwsA(isA<RdpFailure>()),
    );
  });

  test('session defaults deny clipboard audio microphone and files', () {
    const request = RdpSessionRequest(
      profile: profile,
      display: RdpDisplaySpec(
        width: 2560,
        height: 1600,
        desktopScaleFactor: 220,
        externalDisplay: true,
      ),
      certificateFingerprint:
          'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    );
    expect(request.channels, RdpChannelPolicy.lockedDown);
    expect(request.channels.clipboard, isFalse);
    expect(request.channels.audio, isFalse);
    expect(request.channels.microphone, isFalse);
    expect(request.channels.files, isFalse);
    expect(request.display.pixelCount, 4096000);
    request.validate(
      RdpCapabilities.fromJson(fixture()['availableCapabilities']),
    );
  });

  test(
    'clipboard modes are exact and v1 or contradictory booleans fail closed',
    () {
      final packaged = RdpCapabilities.fromJson(packagedCapabilities());
      expect(packaged.supportsIme, isFalse);
      expect(packaged.supportsClipboard, isTrue);
      expect(packaged.supportedClipboardModes, {
        RdpClipboardMode.disabled,
        RdpClipboardMode.clientToRemote,
      });
      expect(
        () => RdpCapabilities.fromJson(
          packagedCapabilities(
            clipboardModes: const ['clientToRemote', 'disabled'],
          ),
        ),
        throwsA(isA<RdpFailure>()),
      );

      final contradictory = jsonDecode(
        jsonEncode(fixture()['availableCapabilities']),
      ) as Map<String, dynamic>;
      (contradictory['channels'] as Map<String, dynamic>)['clipboard'] = true;
      expect(
        () => RdpCapabilities.fromJson(contradictory),
        throwsA(isA<RdpFailure>()),
      );
      final old = jsonDecode(
        File('contracts/rdp-client.v1.json').readAsStringSync(),
      ) as Map;
      expect(
        () => RdpCapabilities.fromJson(old['availableCapabilities']),
        throwsA(isA<RdpFailure>()),
      );
    },
  );

  test('unsupported clipboard selection fails closed without relabelling', () {
    final capabilities = RdpCapabilities.fromJson(packagedCapabilities());
    RdpSessionRequest request(RdpClipboardMode mode) => RdpSessionRequest(
      profile: profile,
      display: const RdpDisplaySpec(
        width: 1920,
        height: 1080,
        desktopScaleFactor: 220,
      ),
      certificateFingerprint:
          'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      settings: RdpProfileSettings(clipboardMode: mode),
      channels: RdpChannelPolicy(clipboard: mode != RdpClipboardMode.disabled),
    );
    request(RdpClipboardMode.clientToRemote).validate(capabilities);
    expect(
      () => request(RdpClipboardMode.bidirectional).validate(capabilities),
      throwsA(isA<RdpFailure>()),
    );
  });

  test('display capability and insecure requests fail closed', () {
    final capabilities = RdpCapabilities.fromJson(
      fixture()['availableCapabilities'],
    );
    for (final display in [
      const RdpDisplaySpec(width: 639, height: 768, desktopScaleFactor: 220),
      const RdpDisplaySpec(width: 1920, height: 1080, desktopScaleFactor: 501),
      const RdpDisplaySpec(width: 9000, height: 1080, desktopScaleFactor: 220),
    ]) {
      expect(
        () => RdpSessionRequest(
          profile: profile,
          display: display,
          certificateFingerprint:
              'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        ).validate(capabilities),
        throwsA(isA<RdpFailure>()),
      );
    }
    expect(
      () => RdpSessionRequest(
        profile: RemoteProfile(
          id: profile.id,
          name: profile.name,
          protocol: RemoteProtocol.ssh,
          host: profile.host,
          port: 22,
          username: profile.username,
        ),
        display: const RdpDisplaySpec(
          width: 1920,
          height: 1080,
          desktopScaleFactor: 220,
        ),
        certificateFingerprint: 'not-a-pin',
      ).validate(capabilities),
      throwsA(isA<RdpFailure>()),
    );
  });
  test(
    'viewport uses valid protocol scale percentages and even bounded width',
    () {
      final spec = RdpDisplaySpec.fromViewport(
        widthPixels: 1921,
        heightPixels: 1080,
        devicePixelRatio: 2,
        externalDisplay: true,
      );
      expect(spec.width, 1920);
      expect(spec.desktopScaleFactor, 200);
      expect(spec.deviceScaleFactor, 180);
      expect(spec.valid, isTrue);
      expect(spec.toChannel().keys, isNot(contains('dpi')));
      expect(
        RdpDisplaySpec.fromViewport(
          widthPixels: 8192,
          heightPixels: 8192,
          devicePixelRatio: 3,
        ).pixelCount,
        lessThanOrEqualTo(16777216),
      );
      for (final invalid in [
        const RdpDisplaySpec(width: 641, height: 480),
        const RdpDisplaySpec(width: 640, height: 480, deviceScaleFactor: 125),
        const RdpDisplaySpec(width: 640, height: 480, desktopScaleFactor: 99),
        const RdpDisplaySpec(width: 8192, height: 8192),
      ]) {
        expect(invalid.valid, isFalse);
      }
      for (final ratio in [double.nan, double.infinity, 0.0, -1.0]) {
        expect(
          () => RdpDisplaySpec.fromViewport(
            widthPixels: 640,
            heightPixels: 480,
            devicePixelRatio: ratio,
          ),
          throwsA(isA<RdpFailure>()),
        );
      }
    },
  );

  test(
    'relative input is signed 16-bit and pointer/wheel require exact geometry',
    () {
      const geometry = RdpFrameGeometry(
        frameSequence: 1,
        width: 640,
        height: 480,
        displayLayoutRevision: 1,
      );
      expect(
        const RdpRelativePointerEvent(
          deltaX: -32768,
          deltaY: 32767,
          buttons: 7,
          geometry: geometry,
        ).valid,
        isTrue,
      );
      expect(
        const RdpRelativePointerEvent(
          deltaX: -32769,
          deltaY: 0,
          buttons: 0,
          geometry: geometry,
        ).valid,
        isFalse,
      );
      expect(
        const RdpPointerEvent(
          x: .5,
          y: .5,
          buttons: 8,
          geometry: geometry,
        ).valid,
        isFalse,
      );
      expect(
        const RdpWheelEvent(wheelDelta: 120, geometry: geometry).valid,
        isTrue,
      );
      expect(
        const RdpWheelEvent(wheelDelta: -120, geometry: geometry).valid,
        isTrue,
      );
      expect(
        const RdpWheelEvent(wheelDelta: 0, geometry: geometry).valid,
        isFalse,
      );
    },
  );
}
