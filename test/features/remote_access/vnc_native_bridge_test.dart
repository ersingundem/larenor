import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/vnc_native_bridge.dart';

const _methods = MethodChannel(VncMethodChannelTransport.methodChannelName);

Map<String, Object?> _binding() => {
  'ownerId': '22222222-2222-4222-8222-222222222222',
  'accountRevision': 7,
  'routeRevision': 11,
};

Map<String, Object?> _capabilities({bool clipboard = false}) => {
  'schemaVersion': 1,
  'availability': 'available',
  'engineRevision': 'rfb-fixture-1',
  'rfbVersions': ['3.8'],
  'securityTypes': ['vencryptTlsVncAuth'],
  'transport': {'tls': true, 'spkiPinning': true},
  'auth': {'password': true},
  'framebuffer': {
    'encodings': ['tight'],
    'trueColor32': true,
    'dynamicResolution': true,
    'externalDisplay': true,
    'maxWidth': 8192,
    'maxHeight': 8192,
    'maxDpi': 640,
  },
  'input': {'pointer': true, 'keyboard': true, 'clipboard': clipboard},
};

Map<String, Object?> _request({bool clipboard = false}) => {
  'schemaVersion': 1,
  'requestId': '11111111-1111-4111-8111-111111111111',
  'targetHost': 'desktop.home.arpa',
  'targetPort': 5900,
  'security': {
    'type': 'vencryptTlsVncAuth',
    'spkiFingerprint': 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'requiresPassword': true,
  },
  'display': {
    'width': 1280,
    'height': 800,
    'dpi': 180,
    'externalDisplay': false,
    'dynamicResolution': true,
  },
  'framebuffer': {'encoding': 'tight', 'pixelFormat': 'trueColor32'},
  'input': {'pointer': true, 'keyboard': true, 'clipboard': clipboard},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(_methods, null));

  test('method channel binds requests and zeroizes password payload', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(_methods, (call) async {
      calls.add(call);
      return switch (call.method) {
        'capabilities' => _capabilities(),
        'open' => {
          'sessionId': '11111111-1111-4111-8111-111111111111',
          'requestId': '11111111-1111-4111-8111-111111111111',
        },
        _ => null,
      };
    });
    final transport = VncMethodChannelTransport(isAndroid: true);
    final binding = VncSessionBinding.fromChannel(_binding());
    await transport.activate(binding);
    final capabilities = await transport.capabilities();
    expect(capabilities.canConnect, isTrue);
    final password = Uint8List.fromList('secret'.codeUnits);
    final opened = await transport.open(
      binding,
      VncBridgeRequest.fromChannel(_request()),
      password,
      capabilities.engineRevision!,
    );
    expect(opened.requestId, '11111111-1111-4111-8111-111111111111');
    expect(password, everyElement(0));
    final payload = calls.last.arguments as Map;
    expect((payload['binding'] as Map), _binding());
    expect(
      payload.keys,
      unorderedEquals([
        'binding',
        'request',
        'expectedEngineRevision',
        'password',
      ]),
    );
    expect(payload['expectedEngineRevision'], 'rfb-fixture-1');
  });

  test(
    'unknown native diagnostics collapse without retry or secret text',
    () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(_methods, (_) async {
        calls++;
        throw PlatformException(
          code: 'raw_socket_error',
          message: 'desktop.home.arpa password=secret',
          details: {'token': 'secret'},
        );
      });
      final transport = VncMethodChannelTransport(isAndroid: true);
      await expectLater(
        transport.capabilities(),
        throwsA(
          isA<VncBridgeException>().having(
            (error) => error.code,
            'code',
            'connectionFailed',
          ),
        ),
      );
      expect(calls, 1);
    },
  );

  test(
    'late capability result after account or route change cancels before open',
    () async {
      final transport = _FakeTransport();
      var current = true;
      final session = VncBridgeSession(
        transport: transport,
        binding: VncSessionBinding.fromChannel(_binding()),
        isCurrent: () => current,
        isForeground: () => true,
      );
      final password = Uint8List.fromList('secret'.codeUnits);
      final start = session.connect(
        VncBridgeRequest.fromChannel(_request()),
        password,
      );
      await Future<void>.delayed(Duration.zero);
      current = false;
      transport.capabilityGate.complete(
        VncBridgeCapabilities.fromChannel(_capabilities()),
      );
      await start;
      expect(transport.opens, 0);
      expect(transport.cancels, 1);
      expect(password, everyElement(0));
      expect(session.phase, VncBridgePhase.retired);
    },
  );

  test(
    'input backpressure and background retirement never queue or replay',
    () async {
      final transport = _FakeTransport()..completeCapabilities();
      final foreground = ValueNotifier(true);
      final session = VncBridgeSession(
        transport: transport,
        binding: VncSessionBinding.fromChannel(_binding()),
        isCurrent: () => true,
        isForeground: () => foreground.value,
      );
      await session.connect(
        VncBridgeRequest.fromChannel(_request()),
        Uint8List.fromList('secret'.codeUnits),
      );
      transport.inputGate = Completer<void>();
      final first = session.input({'kind': 'key', 'code': 40, 'down': true});
      await expectLater(
        session.input({'kind': 'key', 'code': 40, 'down': false}),
        throwsA(
          isA<VncBridgeException>().having((e) => e.code, 'code', 'busy'),
        ),
      );
      expect(transport.inputs, 1);
      transport.inputGate!.complete();
      await first;
      foreground.value = false;
      await session.synchronize();
      expect(transport.cancels, 1);
      await expectLater(
        session.input({'kind': 'key', 'code': 41, 'down': true}),
        throwsA(
          isA<VncBridgeException>().having((e) => e.code, 'code', 'retired'),
        ),
      );
      expect(transport.inputs, 1);
    },
  );

  test(
    'frame sequence requires one explicit ack and retires on gaps',
    () async {
      final transport = _FakeTransport()..completeCapabilities();
      final session = VncBridgeSession(
        transport: transport,
        binding: VncSessionBinding.fromChannel(_binding()),
        isCurrent: () => true,
        isForeground: () => true,
      );
      await session.connect(
        VncBridgeRequest.fromChannel(_request()),
        Uint8List.fromList('secret'.codeUnits),
      );
      transport.frames.add({
        ..._binding(),
        'sessionId': '11111111-1111-4111-8111-111111111111',
        'sequence': 1,
        'width': 1280,
        'height': 800,
        'byteLength': 4096000,
      });
      await Future<void>.delayed(Duration.zero);
      expect(session.pendingFrame?.sequence, 1);
      await session.ackFrame(1);
      expect(transport.acks, [1]);
      transport.frames.add({
        ..._binding(),
        'sessionId': '11111111-1111-4111-8111-111111111111',
        'sequence': 3,
        'width': 1280,
        'height': 800,
        'byteLength': 4096000,
      });
      await Future<void>.delayed(Duration.zero);
      expect(session.phase, VncBridgePhase.retired);
      expect(transport.cancels, 1);
    },
  );

  test('clipboard input requires capability and request opt-in', () async {
    final transport = _FakeTransport()..completeCapabilities(clipboard: true);
    final session = VncBridgeSession(
      transport: transport,
      binding: VncSessionBinding.fromChannel(_binding()),
      isCurrent: () => true,
      isForeground: () => true,
    );
    await session.connect(
      VncBridgeRequest.fromChannel(_request(clipboard: true)),
      Uint8List.fromList('secret'.codeUnits),
    );
    await session.input({'kind': 'clipboard', 'text': 'Merhaba dünya'});
    expect(transport.inputs, 1);

    final deniedTransport = _FakeTransport()
      ..completeCapabilities(clipboard: true);
    final denied = VncBridgeSession(
      transport: deniedTransport,
      binding: VncSessionBinding.fromChannel(_binding()),
      isCurrent: () => true,
      isForeground: () => true,
    );
    await denied.connect(
      VncBridgeRequest.fromChannel(_request()),
      Uint8List.fromList('secret'.codeUnits),
    );
    await expectLater(
      denied.input({'kind': 'clipboard', 'text': 'private'}),
      throwsA(
        isA<VncBridgeException>().having(
          (error) => error.code,
          'code',
          'inputUnavailable',
        ),
      ),
    );
    expect(deniedTransport.inputs, 0);
    await session.retire();
    await denied.retire();
  });
}

class _FakeTransport implements VncNativeTransport {
  final capabilityGate = Completer<VncBridgeCapabilities>();
  final frames = StreamController<Object?>.broadcast();
  int opens = 0, cancels = 0, inputs = 0;
  final acks = <int>[];
  Completer<void>? inputGate;

  void completeCapabilities({bool clipboard = false}) =>
      capabilityGate.complete(
        VncBridgeCapabilities.fromChannel(_capabilities(clipboard: clipboard)),
      );

  @override
  Stream<Object?> get frameEvents => frames.stream;
  @override
  Future<void> activate(VncSessionBinding binding) async {}
  @override
  Future<VncBridgeCapabilities> capabilities() => capabilityGate.future;
  @override
  Future<VncOpenedSession> open(
    VncSessionBinding binding,
    VncBridgeRequest request,
    Uint8List password,
    String expectedEngineRevision,
  ) async {
    opens++;
    expect(expectedEngineRevision, 'rfb-fixture-1');
    password.fillRange(0, password.length, 0);
    return const VncOpenedSession(
      sessionId: '11111111-1111-4111-8111-111111111111',
      requestId: '11111111-1111-4111-8111-111111111111',
    );
  }

  @override
  Future<void> cancel(VncSessionBinding binding) async {
    cancels++;
  }

  @override
  Future<void> input(
    VncSessionBinding binding,
    int sequence,
    Map<String, Object?> event,
  ) async {
    inputs++;
    if (inputGate != null) await inputGate!.future;
  }

  @override
  Future<void> ackFrame(VncSessionBinding binding, int sequence) async {
    acks.add(sequence);
  }
}
