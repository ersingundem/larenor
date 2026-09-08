import 'package:flutter/cupertino.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import '../core_ha_ui_test.dart' show effectiveNodes;
import '../core_ha_tablet_test.dart' show outline,png;
import '../../home_resources/home_resources_tablet_test.dart' show loadFonts;
import '../../../core/home_scope_fixture.dart' show flush;
import 'transfer_ui_fixture.dart';

bool focused(WidgetTester tester,String id)=>Focus.of(tester.element(find.descendant(of:find.byKey(ValueKey(id)),matching:find.byType(Text)))).hasPrimaryFocus;
void main() {
  for(final locale in ['en','tr']) {
    for(final width in [320.0,600.0,1280.0]) {
      testWidgets('$locale $width 2x transfer semantics and real native keyboard', (tester) async {
        await loadFonts(tester);
        tester.platformDispatcher.platformBrightnessTestValue=locale=='tr'?Brightness.dark:Brightness.light;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        final semantics=tester.ensureSemantics();
        try {
        final h=TransferUiHarness(); await h.open(tester,locale:locale,width:width,scale:2); await h.prepare(tester);
        final page=find.byKey(const ValueKey('core-ha-transfer')),l=AppLocalizations.of(tester.element(page));
        for(final pair in [('core-ha-transfer-cancel',l.commonCancel),('core-ha-transfer-confirm',l.coreHaTransferConfirm)]) {
          await transferReveal(tester,find.byKey(ValueKey(pair.$1)));
          final nodes=effectiveNodes(tester,page).where((n)=>n.getSemanticsData().flagsCollection.isButton && n.getSemanticsData().label==pair.$2).toList();
          expect(nodes.length,1); expect(nodes.single.rect.height,greaterThanOrEqualTo(48)); expect(nodes.single.rect.width,greaterThanOrEqualTo(48));
          expect(nodes.single.getSemanticsData().hasAction(SemanticsAction.tap),isTrue);
        }
        FocusManager.instance.primaryFocus?.unfocus();
        final seen=<String>{};
        for(var i=0;i<8&&!seen.contains('core-ha-transfer-confirm');i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab); await tester.pump(); await tester.pump();
          for(final id in ['core-ha-transfer-back','core-ha-transfer-cancel','core-ha-transfer-confirm']) {
            if(!focused(tester,id)) continue; seen.add(id);
            final ring=outline(tester,id),viewport=id.endsWith('back')?Rect.fromLTWH(0,0,width,1000):tester.getRect(find.byKey(const ValueKey('core-ha-scroll')));
            expect(ring.top,greaterThanOrEqualTo(viewport.top)); expect(ring.bottom,lessThanOrEqualTo(viewport.bottom));
            expect(ring.left,greaterThanOrEqualTo(viewport.left)); expect(ring.right,lessThanOrEqualTo(viewport.right));
          }
        }
        expect(seen,containsAll(['core-ha-transfer-cancel','core-ha-transfer-confirm']));
        await png(tester,h,'transfer-$locale-${width.toInt()}-2x');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft); await tester.sendKeyEvent(LogicalKeyboardKey.tab); await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft); await tester.pump(); await tester.pump();
        expect(focused(tester,'core-ha-transfer-cancel'),isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter); await flush(tester);
        expect(h.bound,isFalse); expect(h.transferRequests.where((r)=>r.url.path.endsWith('/confirm')),isEmpty);
        await transferPress(tester,'core-ha-transfer-preview');
        Focus.of(tester.element(find.descendant(of:find.byKey(const ValueKey('core-ha-transfer-confirm')),matching:find.byType(Text)))).requestFocus();
        await tester.pump(); await tester.pump(); await tester.sendKeyEvent(LogicalKeyboardKey.space); await flush(tester);
        expect(find.byKey(const ValueKey('core-ha-transfer-success')),findsOneWidget);
        expect(tester.takeException(),isNull);
        } finally { semantics.dispose(); }
      });
    }
  }
}
