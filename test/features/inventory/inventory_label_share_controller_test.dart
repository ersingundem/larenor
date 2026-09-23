import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/inventory/data/inventory_controller.dart';
import 'package:larenor/features/inventory/data/inventory_qr_share.dart';
import 'package:larenor/features/inventory/domain/inventory_models.dart';
import 'package:larenor/features/inventory/domain/inventory_qr_export.dart';
import 'package:larenor/features/inventory/presentation/inventory_screen.dart';

import 'inventory_controller_test.dart';
import 'inventory_models_test.dart';
import 'inventory_tablet_test.dart' show en;

final class FakeLabelShareGateway implements InventoryQrShareGateway {
  final activation = Completer<void>();
  bool delayActivation = false;
  int activates = 0, shares = 0;
  String? sessionId;
  InventoryQrExport? export;

  @override
  Future<InventoryShareSnapshot> activate(String sessionId) async {
    activates++;
    this.sessionId = sessionId;
    if (delayActivation) await activation.future;
    return const InventoryShareSnapshot(
      supported: true,
      resumed: true,
      focused: true,
      interactionEpoch: 17,
    );
  }

  @override
  Future<void> share({
    required InventoryQrExport export,
    required String sessionId,
    required int interactionEpoch,
  }) async {
    expect(sessionId, this.sessionId);
    expect(interactionEpoch, 17);
    shares++;
    this.export = export;
  }
}

InventoryItem fixtureItem() =>
    InventoryItem.fromResponse(itemResponse(), expected: context);

void main() {
  test('item recreates only its canonical scoped QR for a printable label', () {
    final item = fixtureItem();
    final qr = InventoryQr.forItem(item);
    final export = InventoryQrExport.fromQr(qr);

    expect(qr.context, context);
    expect(qr.itemId, itemId);
    expect(qr.canonical, 'larenor:inventory:v1:$core:$home:$itemId');
    expect(export.svg, isNot(contains(item.label)));
    expect(export.svg, isNot(contains(documentId)));
  });

  test(
    'late native activation cannot share after route authority retires',
    () async {
      var current = true;
      final gateway = FakeLabelShareGateway()..delayActivation = true;
      final controller = InventoryLabelShareController(
        gateway: gateway,
        sessionId: 'inventory-${'9' * 32}',
        isCurrent: () => current,
      );

      final pending = controller.share(fixtureItem());
      await Future<void>.delayed(Duration.zero);
      current = false;
      gateway.activation.complete();
      await pending;

      expect(gateway.activates, 1);
      expect(gateway.shares, 0);
      expect(controller.failure, InventoryLabelShareFailure.stale);
      expect(controller.busy, isFalse);
    },
  );

  testWidgets(
    'tablet detail exposes one explicit 48dp printable-label action',
    (tester) async {
      final gateway = FakeLabelShareGateway();
      final share = InventoryLabelShareController(
        gateway: gateway,
        sessionId: 'inventory-${'9' * 32}',
        isCurrent: () => true,
      );
      final inventory = InventoryController(
        gateway: FakeInventoryGateway(),
        context: context,
        canReadGrants: true,
        isCurrent: () => true,
      );
      await inventory.resolveManual('larenor:inventory:v1:$core:$home:$itemId');

      await tester.pumpWidget(
        CupertinoApp(
          home: InventoryScreen(
            controller: inventory,
            strings: en,
            labelShare: share,
          ),
        ),
      );
      final button = find.byKey(const ValueKey('inventory-share-label'));
      expect(button, findsOneWidget);
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(gateway.activates, 1);
      expect(gateway.shares, 1);
      expect(
        gateway.export?.payload,
        'larenor:inventory:v1:$core:$home:$itemId',
      );
    },
  );
}
