import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/web_panel/data/web_panel_renderer_monitor.dart';
import 'package:larenor/features/web_panel/domain/web_panel_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(WebPanelRendererChannel.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'native renderer attachment is bounded, one-shot and detachable',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      var events = 0;
      final monitor = WebPanelRendererChannel(
        channel: channel,
        attachmentIds: () => '0123456789abcdef0123456789abcdef',
      );
      final policy = WebPanelPolicy.fromUrl(
        'https://fixture.invalid/start',
        additionalOrigins: {WebOrigin.parse('http://login.invalid:8080')!},
      )!;

      final handle = await monitor.attachIdentifier(
        41,
        policy.allowedOrigins,
        () => events++,
      );
      expect(calls.single.method, 'attach');
      expect(calls.single.arguments, {
        'webViewIdentifier': 41,
        'attachmentId': '0123456789abcdef0123456789abcdef',
        'allowedOrigins': [
          {'scheme': 'http', 'host': 'login.invalid', 'port': 8080},
          {'scheme': 'https', 'host': 'fixture.invalid', 'port': 443},
        ],
      });

      await messenger.handlePlatformMessage(
        WebPanelRendererChannel.channelName,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('rendererGone', {
            'attachmentId': '0123456789abcdef0123456789abcdef',
          }),
        ),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);
      expect(events, 1);

      // Native duplicate/stale events never recover a newer controller.
      await messenger.handlePlatformMessage(
        WebPanelRendererChannel.channelName,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('rendererGone', {
            'attachmentId': '0123456789abcdef0123456789abcdef',
          }),
        ),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);
      expect(events, 1);

      await handle.dispose();
      expect(calls, hasLength(1), reason: 'gone attachment is already retired');
    },
  );

  test(
    'dispose revokes callback before native detach acknowledgement',
    () async {
      final detach = Completer<bool>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'attach') return true;
        if (call.method == 'detach') return detach.future;
        fail('unexpected method ${call.method}');
      });
      var events = 0;
      final monitor = WebPanelRendererChannel(
        channel: channel,
        attachmentIds: () => 'abcdef0123456789abcdef0123456789',
      );
      final handle = await monitor.attachIdentifier(
        72,
        WebPanelPolicy.fromUrl('https://fixture.invalid')!.allowedOrigins,
        () => events++,
      );
      final pending = handle.dispose();

      await messenger.handlePlatformMessage(
        WebPanelRendererChannel.channelName,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('rendererGone', {
            'attachmentId': 'abcdef0123456789abcdef0123456789',
          }),
        ),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);
      expect(events, 0);
      detach.complete(true);
      await pending;
    },
  );

  test('malformed ids and rejected native attachment fail closed', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => false);
    final malformed = WebPanelRendererChannel(
      channel: channel,
      attachmentIds: () => 'bad',
    );
    await expectLater(
      malformed.attachIdentifier(
        1,
        WebPanelPolicy.fromUrl('https://fixture.invalid')!.allowedOrigins,
        () {},
      ),
      throwsA(isA<StateError>()),
    );

    final rejected = WebPanelRendererChannel(
      channel: channel,
      attachmentIds: () => '0123456789abcdef0123456789abcdef',
    );
    await expectLater(
      rejected.attachIdentifier(
        1,
        WebPanelPolicy.fromUrl('https://fixture.invalid')!.allowedOrigins,
        () {},
      ),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      rejected.attachIdentifier(1, const {}, () {}),
      throwsA(isA<StateError>()),
    );
  });
}
