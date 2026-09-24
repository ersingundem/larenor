import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/web_panel/data/web_panel_native_effect_port.dart';
import 'package:larenor/features/web_panel/domain/web_panel_native_bridge.dart';

const channel = MethodChannel('test/web-panel-native-effects');

WebPanelBridgeScope scope({int policyRevision = 7}) => WebPanelBridgeScope(
  coreId: '1' * 32,
  homeId: '2' * 32,
  accountId: 'member-1',
  sessionFamily: '3' * 32,
  sourceId: 'dashboard.tile',
  sourceRevision: 4,
  policyRevision: policyRevision,
  routeEpoch: 2,
  lifecycleEpoch: 2,
  topOrigin: 'https://panel.example',
);

WebPanelNativeCommand command() => WebPanelNativeCommand.parse('''{
  "schemaVersion":1,"sequence":1,
  "requestId":"cccccccccccccccccccccccccccccccc",
  "grantId":"dddddddddddddddddddddddddddddddd",
  "method":"speak","payload":{"text":"Dinner is ready","locale":"en-US"}
}''');

WebPanelBridgeTrustedFrame frame(WebPanelBridgeScope value) =>
    WebPanelBridgeTrustedFrame(
      binding: value,
      topOrigin: value.topOrigin,
      mainFrame: true,
      newWindow: false,
      foreground: true,
      routeVisible: true,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'bind' => true,
            'execute' => <String, Object?>{
              'operationId': 'cccccccccccccccccccccccccccccccc',
              'outcome': 'accepted',
              'receiptHandle': 'cccccccccccccccccccccccccccccccc',
            },
            'readback' => true,
            'retire' => null,
            _ => throw MissingPluginException(),
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'bind execute readback and retirement carry no Core secret or URL',
    () async {
      final binding = scope();
      final port = AndroidWebPanelNativeEffectPort(
        channel: channel,
        ownerId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      expect(await port.bind(binding), isTrue);
      final result = await port.execute(command(), frame(binding));
      expect(result.outcome, WebPanelNativePortOutcome.accepted);
      expect(
        await port.readback(result.receiptHandle!, command(), frame(binding)),
        isTrue,
      );
      await port.retire(binding);
      expect(port.capabilities, isEmpty);
      expect(
        calls.map((value) => value.arguments.toString()).join(),
        isNot(
          anyOf(
            contains('accessToken'),
            contains('refreshToken'),
            contains('/api/'),
          ),
        ),
      );
      expect(calls.map((value) => value.method), [
        'bind',
        'execute',
        'readback',
        'retire',
      ]);
    },
  );

  test('scope drift and callback errors fail closed without replay', () async {
    final binding = scope();
    final port = AndroidWebPanelNativeEffectPort(
      channel: channel,
      ownerId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
    await port.bind(binding);
    final rejected = await port.execute(
      command(),
      frame(scope(policyRevision: 8)),
    );
    expect(rejected.outcome, WebPanelNativePortOutcome.rejected);
    expect(calls.where((value) => value.method == 'execute'), isEmpty);
  });
}
