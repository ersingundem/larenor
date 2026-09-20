import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/inventory/data/inventory_qr_share.dart';
import 'package:larenor/features/inventory/domain/inventory_models.dart';
import 'package:larenor/features/inventory/domain/inventory_qr_export.dart';

import 'inventory_models_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(InventoryQrShare.channelName);
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'activateSession' => null,
            'snapshot' => {
              'supported': true,
              'resumed': true,
              'focused': true,
              'interactionEpoch': 7,
            },
            'shareSvg' => null,
            _ => throw PlatformException(code: 'missing'),
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('explicit share sends only bounded canonical SVG authority', () async {
    final qr = InventoryQr.parse('larenor:inventory:v1:$core:$home:$itemId');
    final export = InventoryQrExport.fromQr(qr);
    final bridge = InventoryQrShare();
    final snapshot = await bridge.activate('inventory-session-1');
    expect(snapshot.supported, isTrue);
    await bridge.share(
      export: export,
      sessionId: 'inventory-session-1',
      interactionEpoch: snapshot.interactionEpoch,
    );
    expect(calls.map((call) => call.method), [
      'activateSession',
      'snapshot',
      'shareSvg',
    ]);
    final arguments = calls.last.arguments! as Map<Object?, Object?>;
    expect(arguments.keys, {
      'sessionId',
      'interactionEpoch',
      'fileName',
      'mimeType',
      'svg',
    });
    expect(arguments['fileName'], 'larenor-inventory-$itemId.svg');
    expect(arguments['mimeType'], 'image/svg+xml');
    expect(arguments['svg'], export.svg);
    expect(arguments.toString(), isNot(contains('Kahve değirmeni')));
  });

  test(
    'invalid session and epoch are rejected before native dispatch',
    () async {
      final export = InventoryQrExport.fromQr(
        InventoryQr.parse('larenor:inventory:v1:$core:$home:$itemId'),
      );
      final bridge = InventoryQrShare();
      expect(() => bridge.activate('../bad'), throwsArgumentError);
      expect(
        () => bridge.share(
          export: export,
          sessionId: 'inventory-session-1',
          interactionEpoch: -1,
        ),
        throwsArgumentError,
      );
      expect(calls, isEmpty);
    },
  );
}
