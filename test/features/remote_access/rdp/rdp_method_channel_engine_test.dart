import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/rdp/rdp_engine.dart';
import 'package:larenor/features/remote_access/rdp/rdp_models.dart';

import 'rdp_models_test.dart' show fixture, profile;

class ClipboardMethods extends MethodChannel {
  ClipboardMethods(this.onClipboard) : super('rdp-test-methods');
  final Future<void> Function(Uint8List) onClipboard;

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    if (method == 'input' && (arguments as Map)['kind'] == 'channel') {
      await onClipboard(arguments['payload'] as Uint8List);
      return null;
    }
    return super.invokeMethod<T>(method, arguments);
  }
}

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

  Future<RdpChannel> openClipboard(
    RdpMethodChannelEngine engine, {
    bool Function()? current,
    bool enabled = true,
  }) => engine.open(
    RdpSessionRequest(
      profile: profile,
      display: const RdpDisplaySpec(width: 640, height: 480, dpi: 160),
      certificateFingerprint:
          'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      settings: RdpProfileSettings(
        clipboardMode: enabled
            ? RdpClipboardMode.clientToRemote
            : RdpClipboardMode.disabled,
      ),
      channels: RdpChannelPolicy(clipboard: enabled),
    ),
    credential: const RdpCredential(password: 'temporary'),
    isCurrent: current ?? () => true,
  );

  test(
    'clipboard uses typed UTF-8 channel input and shared ordered sequence',
    () async {
      final engine = RdpMethodChannelEngine(
        methods: methods,
        events: events,
        isAndroid: true,
      );
      final channel = await openClipboard(engine);
      channel.key(const RdpKeyEvent(physicalKey: 30, down: true));
      expect(await channel.sendClipboardText('İstanbul\n😀'), isTrue);
      channel.text('composed');
      await Future<void>.delayed(Duration.zero);
      final inputs = calls.where((c) => c.method == 'input').toList();
      expect(inputs.map((c) => (c.arguments as Map)['sequence']), [1, 2, 3]);
      final clipboard = inputs[1].arguments as Map;
      expect(clipboard.keys.toSet(), {
        'requestId',
        'sequence',
        'kind',
        'channel',
        'payload',
      });
      expect(clipboard['kind'], 'channel');
      expect(clipboard['channel'], 'clipboard');
      expect(clipboard['payload'], isA<Uint8List>());
      expect(utf8.decode(clipboard['payload'] as Uint8List), 'İstanbul\n😀');
      expect(
        clipboard['requestId'],
        (calls.singleWhere((c) => c.method == 'open').arguments
            as Map)['requestId'],
      );
      for (final value in ['', 'bad\u0000text', '\ud800', '😀' * 16385]) {
        expect(await channel.sendClipboardText(value), isFalse);
      }
      expect(calls.where((c) => c.method == 'input'), hasLength(3));
      channel.close();
      engine.close();
    },
  );

  test(
    'clipboard opt-out or stale authority never dispatches native input',
    () async {
      var current = true;
      final engine = RdpMethodChannelEngine(
        methods: methods,
        events: events,
        isAndroid: true,
      );
      final off = await openClipboard(engine, enabled: false);
      expect(await off.sendClipboardText('private'), isFalse);
      off.close();
      final on = await openClipboard(engine, current: () => current);
      current = false;
      expect(await on.sendClipboardText('private'), isFalse);
      expect(calls.where((c) => c.method == 'input'), isEmpty);
      on.close();
      engine.close();
    },
  );

  for (final failure in [false, true]) {
    test(
      'clipboard zeroes original payload after ${failure ? 'native failure' : 'late authority retirement'}',
      () async {
        Uint8List? original;
        var current = true;
        final reply = Completer<void>();
        final direct = ClipboardMethods((bytes) async {
          original = bytes;
          expect(utf8.decode(bytes), 'private');
          await reply.future;
          if (failure) throw PlatformException(code: 'invalidRequest');
        });
        final engine = RdpMethodChannelEngine(
          methods: direct,
          events: events,
          isAndroid: true,
        );
        final channel = await openClipboard(engine, current: () => current);
        final pending = channel.sendClipboardText('private');
        await Future<void>.delayed(Duration.zero);
        if (!failure) current = false;
        reply.complete();
        expect(await pending, isFalse);
        expect(original, isNotNull);
        expect(original, everyElement(0));
        channel.close();
        engine.close();
      },
    );
  }

  test(
    'lost native clipboard reply closes exact channel and wipes bytes',
    () async {
      Uint8List? original;
      final reply = Completer<void>();
      final direct = ClipboardMethods((bytes) async {
        original = bytes;
        await reply.future;
      });
      final engine = RdpMethodChannelEngine(
        methods: direct,
        events: events,
        isAndroid: true,
      );
      final channel = await openClipboard(engine);
      fakeAsync((async) {
        bool? accepted;
        channel
            .sendClipboardText('private')
            .then((result) => accepted = result);
        async.flushMicrotasks();
        expect(original, isNotNull);
        async.elapse(const Duration(seconds: 6));
        async.flushMicrotasks();
        expect(accepted, isFalse);
        expect(original, everyElement(0));
        reply.complete();
        async.flushMicrotasks();
        expect(accepted, isFalse);
      });
      expect(await channel.sendClipboardText('no-replay'), isFalse);
      expect(calls.where((c) => c.method == 'cancel'), hasLength(1));
      engine.close();
    },
  );

  test('verified native capability and probe stay exact and scoped', () async {
    final engine = RdpMethodChannelEngine(
      methods: methods,
      events: events,
      isAndroid: true,
    );
    final capabilities = await engine.capabilities(isCurrent: () => true);
    expect(capabilities.canConnect, isTrue);
    final probe = await engine.inspect(profile, isCurrent: () => true);
    expect(probe.tlsCertificateObserved, isTrue);
    expect(probe.clientRequiresNla, isTrue);
    expect(probe.certificate.algorithm, 'spki-sha256');
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
      channel.text('İstanbul');
      await Future<void>.delayed(Duration.zero);
      final ime = calls.singleWhere(
        (call) =>
            call.method == 'input' && (call.arguments as Map)['kind'] == 'ime',
      );
      expect(ime.arguments, {
        'requestId': arguments['requestId'],
        'sequence': 1,
        'kind': 'ime',
        'text': 'İstanbul',
      });
      channel.text('');
      channel.text('x' * 4097);
      channel.text('\ud800');
      await Future<void>.delayed(Duration.zero);
      expect(
        calls.where(
          (call) =>
              call.method == 'input' &&
              (call.arguments as Map)['kind'] == 'ime',
        ),
        hasLength(1),
      );
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
