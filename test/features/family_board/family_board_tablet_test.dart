import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/family_board/data/family_board_controller.dart';
import 'package:larenor/features/family_board/domain/family_board_models.dart';
import 'package:larenor/features/family_board/presentation/family_board_screen.dart';

import 'family_board_controller_test.dart';

const en = FamilyBoardStrings(
  title: 'Family board',
  cards: 'Cards',
  whiteboard: 'Whiteboard',
  newCard: 'New card',
  editCard: 'Edit card',
  save: 'Save',
  cancel: 'Cancel',
  delete: 'Delete',
  addMark: 'Add accessible mark',
  refresh: 'Refresh changes',
  offline: 'Offline snapshot · read only',
  conflict: 'Board changed · reload required',
  empty: 'No cards yet',
  drawingHint: 'Draw with touch or add a mark with keyboard',
  loading: 'Loading family board',
  unavailable: 'Board unavailable',
);
const tr = FamilyBoardStrings(
  title: 'Aile panosu',
  cards: 'Kartlar',
  whiteboard: 'Beyaz tahta',
  newCard: 'Yeni kart',
  editCard: 'Kartı düzenle',
  save: 'Kaydet',
  cancel: 'İptal',
  delete: 'Sil',
  addMark: 'Erişilebilir işaret ekle',
  refresh: 'Değişiklikleri yenile',
  offline: 'Çevrimdışı görünüm · salt okunur',
  conflict: 'Pano değişti · yeniden yükle',
  empty: 'Henüz kart yok',
  drawingHint: 'Dokunarak çiz veya klavyeyle işaret ekle',
  loading: 'Aile panosu yükleniyor',
  unavailable: 'Pano kullanılamıyor',
);

void main() {
  for (final width in [600.0, 1200.0]) {
    for (final strings in [en, tr]) {
      testWidgets(
        '$width @2x ${strings.title} is overflow-free and accessible',
        (tester) async {
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final gateway = FakeBoardGateway();
          final controller = FamilyBoardController(
            gateway: gateway,
            cache: MemoryBoardCache(),
            binding: binding(),
            isCurrent: (_) => true,
            idFactory: () => '8' * 32,
          );
          await controller.load();
          final semantics = tester.ensureSemantics();
          await tester.pumpWidget(
            CupertinoApp(
              home: MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 1000),
                  textScaler: const TextScaler.linear(2),
                ),
                child: FamilyBoardScreen(
                  controller: controller,
                  strings: strings,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          for (final key in [
            'family-board-new',
            'family-board-refresh',
            'family-board-mark',
          ]) {
            expect(
              tester.getSize(find.byKey(ValueKey(key))).height,
              greaterThanOrEqualTo(48),
            );
          }
          final canvas = tester.getSemantics(
            find.byKey(const ValueKey('family-board-canvas')),
          );
          expect(canvas.getSemanticsData().label, strings.drawingHint);
          expect(canvas.getSemanticsData().flagsCollection.isButton, isTrue);
          semantics.dispose();
        },
      );
    }
  }

  testWidgets(
    'keyboard creates card and accessible mark, then edit/delete act once',
    (tester) async {
      final gateway = FakeBoardGateway();
      final controller = FamilyBoardController(
        gateway: gateway,
        cache: MemoryBoardCache(),
        binding: binding(),
        isCurrent: (_) => true,
        idFactory: (() {
          var n = 8;
          return () => (n++).toRadixString(16).padLeft(32, '0');
        })(),
      );
      await controller.load();
      await tester.pumpWidget(
        CupertinoApp(
          home: FamilyBoardScreen(controller: controller, strings: en),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('family-board-new')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('family-board-editor')),
        'Yeni kart',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(gateway.mutations, 1);

      await tester.ensureVisible(
        find.byKey(const ValueKey('family-board-canvas')),
      );
      await tester.tap(find.byKey(const ValueKey('family-board-canvas')));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(gateway.mutations, 2);
      expect(gateway.commands.last.element!.kind, BoardElementKind.stroke);

      await tester.ensureVisible(find.text('Film gecesi').first);
      await tester.tap(find.text('Film gecesi').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('family-board-editor')),
        'Düzenlenen kart',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(gateway.mutations, 3);

      await tester.ensureVisible(find.text('Düzenlenen kart').first);
      await tester.tap(find.text('Düzenlenen kart').first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('family-board-delete')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('family-board-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.delete).last);
      await tester.pumpAndSettle();
      expect(gateway.mutations, 4);
    },
  );

  testWidgets('lifecycle retirement disables all board mutations', (
    tester,
  ) async {
    final controller = FamilyBoardController(
      gateway: FakeBoardGateway(),
      cache: MemoryBoardCache(),
      binding: binding(),
      isCurrent: (_) => true,
      idFactory: () => '88888888888888888888888888888888',
    );
    await controller.load();
    await tester.pumpWidget(
      CupertinoApp(
        home: FamilyBoardScreen(controller: controller, strings: en),
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(controller.failure, BoardFailure.stale);
    expect(controller.canMutate, isFalse);
    final action = find.descendant(
      of: find.byKey(const ValueKey('family-board-new')),
      matching: find.byType(CupertinoButton),
    );
    expect(tester.widget<CupertinoButton>(action).onPressed, isNull);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}
