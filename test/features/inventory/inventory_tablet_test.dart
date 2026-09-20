import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/inventory/data/inventory_controller.dart';
import 'package:larenor/features/inventory/presentation/inventory_screen.dart';

import 'inventory_controller_test.dart';
import 'inventory_models_test.dart';

const en = InventoryStrings(
  title: 'Home inventory',
  manualLabel: 'Inventory QR',
  open: 'Open item',
  emptyTitle: 'No resolved items',
  emptyBody: 'Scan or enter an inventory QR.',
  room: 'Room',
  device: 'Device',
  documents: 'Documents',
  grants: 'Readers',
  audit: 'Verified history',
  loading: 'Opening inventory item',
  accessVerified: 'Read access verified',
  invalidQr: 'Invalid inventory QR',
  foreignQr: 'QR belongs to another home',
  offline: 'Core is offline',
  stale: 'Session changed; result discarded',
  invalidResponse: 'Unverified Core response',
);
const tr = InventoryStrings(
  title: 'Ev envanteri',
  manualLabel: 'Envanter QR kodu',
  open: 'Eşyayı aç',
  emptyTitle: 'Çözümlenmiş eşya yok',
  emptyBody: 'Envanter QR kodunu tara veya gir.',
  room: 'Oda',
  device: 'Cihaz',
  documents: 'Belgeler',
  grants: 'Okuyucular',
  audit: 'Doğrulanmış geçmiş',
  loading: 'Envanter eşyası açılıyor',
  accessVerified: 'Okuma erişimi doğrulandı',
  invalidQr: 'Geçersiz envanter QR kodu',
  foreignQr: 'QR başka bir eve ait',
  offline: 'Core çevrimdışı',
  stale: 'Oturum değişti; sonuç kullanılmadı',
  invalidResponse: 'Doğrulanmamış Core yanıtı',
);

void main() {
  for (final width in [600.0, 1200.0]) {
    for (final strings in [en, tr]) {
      testWidgets('tablet $width supports 2x text, TalkBack and keyboard', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = InventoryController(
          gateway: FakeInventoryGateway(),
          context: context,
          canReadGrants: true,
          isCurrent: () => true,
        );
        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(
          CupertinoApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 900),
                textScaler: const TextScaler.linear(2),
              ),
              child: InventoryScreen(controller: controller, strings: strings),
            ),
          ),
        );
        await tester.enterText(
          find.byKey(const ValueKey('inventory-manual-entry')),
          'larenor:inventory:v1:$core:$home:$itemId',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Kahve değirmeni'), findsWidgets);
        expect(find.textContaining(roomId), findsOneWidget);
        expect(find.textContaining(documentId), findsOneWidget);
        expect(find.bySemanticsLabel(strings.accessVerified), findsOneWidget);
        final button = find.byKey(const ValueKey('inventory-open'));
        expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
        semantics.dispose();
      });
    }
  }
}
