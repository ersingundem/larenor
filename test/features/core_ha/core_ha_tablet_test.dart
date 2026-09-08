import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import '../../core/home_scope_fixture.dart' show flush;
import '../home_resources/home_resources_tablet_test.dart' show loadFonts;
import 'core_ha_ui_boundary_test.dart' show preview;
import 'core_ha_ui_fixture.dart';
import 'core_ha_ui_test.dart' show key, press, reveal, openBinding, openSnapshot;

Finder native(String id) => find.descendant(of: key(id), matching: find.byType(CupertinoButton));
List<SemanticsNode> effective(WidgetTester tester) {
  final result = <SemanticsNode>[];
  void visit(SemanticsNode node) {
    if (!node.isMergedIntoParent) result.add(node);
    node.visitChildren((child) { visit(child); return true; });
  }
  visit(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
  return result;
}
bool focused(WidgetTester tester, String id) => Focus.of(tester.element(find.descendant(of: key(id), matching: find.byType(Text)))).hasPrimaryFocus;
Rect outline(WidgetTester tester, String id) {
  final box = find.descendant(of: native(id), matching: find.byWidgetPredicate((w) => w is DecoratedBox && w.decoration is ShapeDecoration && (w.decoration as ShapeDecoration).shape is OutlinedBorder)).first;
  final border = (tester.widget<DecoratedBox>(box).decoration as ShapeDecoration).shape as OutlinedBorder;
  expect(border.side.width, greaterThan(0));
  final bg = CupertinoColors.secondarySystemGroupedBackground.resolveFrom(tester.element(box));
  final color = Color.alphaBlend(border.side.color, bg);
  final a = color.computeLuminance(), b = bg.computeLuminance();
  expect(((a > b ? a : b) + .05) / ((a > b ? b : a) + .05), greaterThanOrEqualTo(3));
  return tester.getRect(box).inflate(border.side.strokeOutset);
}
Future<void> png(WidgetTester tester, HaUiHarness h, String name) async {
  const path = String.fromEnvironment('CORE_HA_PREVIEW_DIR');
  if (path.isEmpty) return;
  await tester.runAsync(() async {
    final image = await (h.boundary.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory(path).createSync(recursive: true);
      File('$path/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    } finally { image.dispose(); }
  });
}
void main() {
  for (final locale in ['en', 'tr']) {
    for (final width in [320.0, 600.0, 1280.0]) {
      for (final dark in [false, true]) {
        testWidgets('$locale $width ${dark ? 'dark' : 'light'} 2x real-font binding effective semantics and native Tab viewport', (tester) async {
          await loadFonts(tester);
          tester.platformDispatcher.platformBrightnessTestValue = dark ? Brightness.dark : Brightness.light;
          addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
          final semantics = tester.ensureSemantics();
          try {
            final h = HaUiHarness(); await openBinding(tester, h, locale: locale, width: width, scale: 2);
            await preview(tester, h);
            final l = AppLocalizations.of(tester.element(key('core-ha-binding')));
            await reveal(tester, key('core-ha-preview-details'));
            for (final text in [l.coreHaPreviewDetails]) {
              expect(effective(tester).where((n) => n.getSemanticsData().flagsCollection.isHeader && n.getSemanticsData().label == text).length, 1);
            }
            for (final pair in [('core-ha-cancel', l.commonCancel), ('core-ha-confirm', l.coreHaConfirm)]) {
              await reveal(tester, native(pair.$1));
              final nodes = effective(tester).where((n) => n.getSemanticsData().flagsCollection.isButton && n.getSemanticsData().label == pair.$2).toList();
              expect(nodes.length, 1);
              expect(nodes.single.rect.height, greaterThanOrEqualTo(48));
              expect(nodes.single.rect.width, greaterThanOrEqualTo(48));
              expect(nodes.single.getSemanticsData().flagsCollection.isHeader, isFalse);
            }
            FocusManager.instance.primaryFocus?.unfocus();
            final seen = <String>{};
            for (var i = 0; i < 6 && !seen.contains('core-ha-confirm'); i++) {
              await tester.sendKeyEvent(LogicalKeyboardKey.tab); await tester.pump(); await tester.pump();
              for (final id in ['core-ha-back', 'core-ha-refresh', 'core-ha-cancel', 'core-ha-confirm']) {
                if (!focused(tester, id)) continue;
                seen.add(id);
                final ring = outline(tester, id), viewport = id == 'core-ha-back' ? Rect.fromLTWH(0, 0, width, 1000) : tester.getRect(key('core-ha-scroll'));
                expect(ring.left, greaterThanOrEqualTo(viewport.left)); expect(ring.right, lessThanOrEqualTo(viewport.right));
                expect(ring.top, greaterThanOrEqualTo(viewport.top), reason: id);
                expect(ring.bottom, lessThanOrEqualTo(viewport.bottom), reason: id);
              }
            }
            expect(seen, containsAll(['core-ha-cancel', 'core-ha-confirm']));
            await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft); await tester.pump(); await tester.pump();
            expect(focused(tester, 'core-ha-cancel'), isTrue);
            final ring = outline(tester, 'core-ha-cancel'), viewport = tester.getRect(key('core-ha-scroll'));
            expect(ring.top, greaterThanOrEqualTo(viewport.top)); expect(ring.bottom, lessThanOrEqualTo(viewport.bottom));
            await png(tester, h, '$locale-${width.toInt()}-${dark ? 'dark' : 'light'}-binding-2x');
            await tester.sendKeyEvent(LogicalKeyboardKey.enter); await flush(tester);
            expect(h.adapterRequests.where((r) => r.url.path.endsWith('/binding-confirm')), isEmpty);
            expect(h.haReads, 0); expect(tester.takeException(), isNull);
          } finally { semantics.dispose(); }
        });
      }
    }
  }
  for (final pair in [('en', 1280.0), ('tr', 600.0)]) {
    testWidgets('${pair.$1} real-font read-only snapshot refresh and Space activation', (tester) async {
      await loadFonts(tester);
      tester.platformDispatcher.platformBrightnessTestValue = pair.$1 == 'tr' ? Brightness.dark : Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final h = HaUiHarness()..role = 'member'; await openSnapshot(tester, h, locale: pair.$1, width: pair.$2, scale: 2);
      await reveal(tester, key('core-ha-refresh'));
      Focus.of(tester.element(find.descendant(of: key('core-ha-refresh'), matching: find.byType(Text)))).requestFocus();
      await tester.pump(); await tester.sendKeyEvent(LogicalKeyboardKey.space); await flush(tester);
      expect(h.snapshotReads, 2); expect(key('core-ha-state-off'), findsOneWidget);
      await png(tester, h, '${pair.$1}-${pair.$2.toInt()}-snapshot-2x');
      expect(h.adapterRequests.every((r) => r.method == 'GET'), isTrue); expect(h.haReads, 0);
    });
  }
}
