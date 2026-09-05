import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import '../../core/home_scope_fixture.dart' show flush;
import 'home_resources_fixture.dart';

bool fontsLoaded = false;
Future<void> loadFonts(WidgetTester tester) async {
  if (fontsLoaded) return;
  await tester.runAsync(() async {
    final font = await rootBundle.load('assets/fonts/Inter-Variable.ttf');
    for (final family in ['Inter','CupertinoSystemText','CupertinoSystemDisplay']) {
      await (FontLoader(family)..addFont(Future.value(font))).load();
    }
    await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'))).load();
  });
  fontsLoaded = true;
}
void main() {
  for (final locale in ['en','tr']) {
    for (final width in [600.0,1200.0]) {
      for (final dark in [false,true]) {
        testWidgets('Core resources real-font $locale $width ${dark ? 'dark' : 'light'} 2x', (tester) async {
          await loadFonts(tester);
          final semantics = tester.ensureSemantics();
          try {
          tester.platformDispatcher.platformBrightnessTestValue = dark ? Brightness.dark : Brightness.light;
          addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
          final h = ResourceHarness()..response = contract()['adminList'];
          await h.mount(tester, locale:locale,width:width,scale:2); await h.signIn(); await flush(tester);
          final refresh = find.byKey(const ValueKey('home-resources-refresh'));
          final l10n = AppLocalizations.of(tester.element(refresh));
          final title = find.text(l10n.homeResourcesTitle);
          await tester.ensureVisible(title); await flush(tester);
          expect(tester.getSemantics(title).flagsCollection.isHeader, isTrue);
          await tester.ensureVisible(refresh); await flush(tester);
          final refreshNode = tester.getSemantics(find.text(l10n.commonRefresh));
          expect(refreshNode.label, l10n.commonRefresh);
          expect(refreshNode.flagsCollection.isButton, isTrue);
          expect(refreshNode.flagsCollection.isHeader, isFalse);
          expect(refreshNode.rect.height, greaterThanOrEqualTo(48));
          expect(find.bySemanticsLabel(l10n.commonRefresh), findsOneWidget);
          final caption = find.text(l10n.commonRefresh);
          Focus.of(tester.element(caption)).requestFocus(); await flush(tester);
          expect(Focus.of(tester.element(caption)).hasPrimaryFocus, isTrue);
          // The preceding source action and refresh remain distinct tab targets.
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft); await flush(tester);
          expect(Focus.of(tester.element(find.text(l10n.homeSourceTitle))).hasPrimaryFocus, isTrue);
          await tester.sendKeyEvent(LogicalKeyboardKey.tab); await flush(tester);
          expect(Focus.of(tester.element(caption)).hasPrimaryFocus, isTrue);
          final count = h.resourceReads;
          await tester.sendKeyEvent(LogicalKeyboardKey.enter); await flush(tester); expect(h.resourceReads, count + 1);
          await tester.sendKeyEvent(LogicalKeyboardKey.space); await flush(tester); expect(h.resourceReads, count + 2);
          final focusDecorations = find.descendant(of: refresh, matching: find.byWidgetPredicate((w) => w is DecoratedBox && w.decoration is ShapeDecoration && (w.decoration as ShapeDecoration).shape is OutlinedBorder));
          final outline = (tester.widget<DecoratedBox>(focusDecorations.first).decoration as ShapeDecoration).shape as OutlinedBorder;
          final background = CupertinoTheme.of(tester.element(refresh)).scaffoldBackgroundColor;
          final lighter = outline.side.color.computeLuminance(), darker = background.computeLuminance();
          final contrast = ((lighter > darker ? lighter : darker) + .05) / ((lighter < darker ? lighter : darker) + .05);
          expect(contrast, greaterThanOrEqualTo(3));
          await tester.ensureVisible(refresh); await flush(tester);
          final rect = tester.getRect(refresh); expect(rect.left, greaterThanOrEqualTo(4)); expect(rect.right, lessThanOrEqualTo(width - 4));
          const output = String.fromEnvironment('CORE_RESOURCES_PREVIEW_DIR');
          if (output.isNotEmpty && locale == 'tr' && width == 600) {
            await tester.runAsync(() async {
              final render = h.boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
              final picture = await render.toImage(pixelRatio:1);
              try {
                final png = await picture.toByteData(format:ui.ImageByteFormat.png);
                Directory(output).createSync(recursive:true);
                File('$output/core-resources-tr-600-2x-${dark ? 'dark' : 'light'}.png').writeAsBytesSync(png!.buffer.asUint8List());
              } finally {picture.dispose();}
            });
          }
          final unicode = h.fixture['unicodeRecord']['record'];
          final last = find.byKey(ValueKey('home-resource-${unicode['ref']['id']}'));
          await tester.scrollUntilVisible(last, 400, scrollable: find.byType(Scrollable).first, maxScrolls:20); await flush(tester);
          expect(find.text(unicode['label'] as String), findsOneWidget);
          for (final element in find.descendant(of:last,matching:find.byType(RichText)).evaluate()) {
            final paragraph = element.renderObject! as RenderParagraph;
            expect(paragraph.didExceedMaxLines, isFalse);
            expect(paragraph.size.width, lessThanOrEqualTo(width - 48));
          }
          expect(tester.takeException(), isNull); expect(h.haReads, 0);
          } finally {semantics.dispose();}
        });
      }
    }
  }
}
