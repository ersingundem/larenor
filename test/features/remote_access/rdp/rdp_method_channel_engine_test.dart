import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/rdp/rdp_engine.dart';
import 'package:larenor/features/remote_access/rdp/rdp_models.dart';

import 'rdp_models_test.dart' show fixture, profile;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('rdp-test-methods');
  const events = EventChannel('rdp-test-events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls.clear();
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return switch (call.method) {
        'capabilities' => fixture()['availableCapabilities'],
        'inspect' => {
          'tls': true,
          'requiresNla': true,
          'certificateFingerprint':
              'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        },
        'activate' ||
        'open' ||
        'input' ||
        'resize' ||
        'ackFrame' ||
        'cancel' => null,
        _ => throw MissingPluginException(),
      };
    });
    messenger.setMockMessageHandler(events.name, (message) async {
      final call = const StandardMethodCodec().decodeMethodCall(message);
      expect(call.method, anyOf('listen', 'cancel'));
      return const StandardMethodCodec().encodeSuccessEnvelope(null);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMessageHandler(events.name, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('verified native capability and probe stay exact and scoped', () async {
    final engine = RdpMethodChannelEngine(
      methods: methods,
      events: events,
      isAndroid: true,
    );
    final capabilities = await engine.capabilities(isCurrent: () => true);
    expect(capabilities.canConnect, isTrue);
    final security = await engine.inspect(profile, isCurrent: () => true);
    expect(security.requiresNla, isTrue);
    expect(security.certificate.algorithm, 'spki-sha256');
    expect(calls[1].arguments, {
      'targetHost': profile.host,
      'targetPort': profile.port,
      'username': profile.username,
    });
    engine.close();
  });

  test(
    'open forwards locked policy and one bounded frame acknowledgement',
    () async {
      final engine = RdpMethodChannelEngine(
        methods: methods,
        events: events,
        isAndroid: true,
      );
      final request = RdpSessionRequest(
        profile: profile,
        display: const RdpDisplaySpec(width: 640, height: 480, dpi: 160),
        certificateFingerprint:
            'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        settings: const RdpProfileSettings(
          clipboardMode: RdpClipboardMode.clientToRemote,
        ),
        channels: const RdpChannelPolicy(clipboard: true),
      );
      final opened = await engine.open(
        request,
        credential: const RdpCredential(password: 'temporary'),
        isCurrent: () => true,
      );
      final open = calls.singleWhere((call) => call.method == 'open');
      final arguments = open.arguments as Map;
      final native = arguments['request'] as Map;
      expect(native['requiresNla'], isTrue);
      expect(native['clipboardMode'], 'clientToRemote');
      expect(native['audio'], isFalse);
      expect(native['files'], isFalse);
      expect(arguments['password'], isA<Uint8List>());
      expect(arguments.values, isNot(contains('temporary')));

      final channel = opened as RdpFrameChannel;
      final frameFuture = channel.frames.first;
      final requestId = arguments['requestId'] as String;
      final pixels = Uint8List(640 * 480 * 4);
      await messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'requestId': requestId,
          'kind': 'frame',
          'payload': {
            'sequence': 1,
            'width': 640,
            'height': 480,
            'stride': 2560,
            'dpi': 160,
            'pixels': pixels,
          },
        }),
        (_) {},
      );
      final frame = await frameFuture;
      expect(frame.bgra, hasLength(pixels.length));
      await channel.acknowledgeFrame(frame.sequence);
      expect(calls.where((call) => call.method == 'ackFrame'), hasLength(1));
      channel.close();
    },
  );
}
