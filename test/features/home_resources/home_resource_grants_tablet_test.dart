import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import '../../core/home_scope_fixture.dart' show flush;
import 'home_resource_admin_fixture.dart';
import 'home_resource_grants_ui_test.dart';
import 'home_resources_tablet_test.dart' show loadFonts;

Future<void> capture(WidgetTester tester, GrantsHarness h, String name) async {
  const output = String.fromEnvironment('CORE_RESOURCE_GRANTS_PREVIEW_DIR');
  if (output.isEmpty) return;
  await tester.runAsync(() async {
    final boundary =
        h.boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory(output).createSync(recursive: true);
      File('$output/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  for (final locale in ['en', 'tr']) {
    for (final width in [320.0, 600.0, 1280.0]) {
      testWidgets(
        'grants $locale $width 2x named 48px controls and Tab Enter selection',
        (tester) async {
          await loadFonts(tester);
          final semantics = tester.ensureSemantics();
          try {
            final h = GrantsHarness();
            await h.mount(tester, locale: locale, width: width, scale: 2);
            await h.signIn();
            await flush(tester);
            await tester.scrollUntilVisible(
              adminKey('home-resources-manage'),
              300,
              scrollable: find.byType(Scrollable).first,
              maxScrolls: 20,
            );
            await adminPress(tester, 'home-resources-manage');
            await adminPress(tester, 'home-resource-grants-${h.targetId}');
            expect(
              tester.getSize(adminKey('resource-grants-back')).height,
              greaterThanOrEqualTo(48),
            );
            final user = adminKey('resource-grants-user-${'3' * 32}');
            await tester.ensureVisible(user);
            await flush(tester);
            final node = tester.getSemantics(find.text('person_3'));
            expect(
              node.label,
              'person_3\n${AppLocalizations.of(tester.element(user)).resourceGrantsNone}',
            );
            expect(node.flagsCollection.isButton, isTrue);
            expect(node.rect.height, greaterThanOrEqualTo(48));
            Focus.of(tester.element(find.text('person_3'))).requestFocus();
            await flush(tester);
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await flush(tester);
            expect(adminKey('resource-grants-user-${'2' * 32}'), findsNothing);
            final read = adminKey('resource-grants-readOnly');
            await tester.ensureVisible(read);
            await flush(tester);
            final l10n = AppLocalizations.of(tester.element(read));
            expect(
              find.descendant(
                of: read,
                matching: find.byIcon(CupertinoIcons.checkmark),
              ),
              findsOneWidget,
            );
            expect(
              tester
                  .getSemantics(find.text(l10n.resourceGrantsReadOnly))
                  .flagsCollection
                  .isSelected,
              ui.Tristate.isTrue,
            );
            Focus.of(tester.element(find.text(l10n.resourceGrantsReadOnly)))
                .requestFocus();
            await flush(tester);
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await flush(tester);
            expect(
              Focus.of(tester.element(find.text(l10n.resourceGrantsReadWrite)))
                  .hasPrimaryFocus,
              isTrue,
            );
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await flush(tester);
            expect(
              find.descendant(
                of: adminKey('resource-grants-readWrite'),
                matching: find.byIcon(CupertinoIcons.checkmark),
              ),
              findsOneWidget,
            );
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await flush(tester);
            expect(
              Focus.of(tester.element(find.text(l10n.commonSave)))
                  .hasPrimaryFocus,
              isTrue,
            );
            for (final key in [
              'resource-grants-readOnly',
              'resource-grants-readWrite',
              'resource-grants-none',
              'resource-grants-save',
              'resource-grants-cancel',
            ]) {
              await tester.ensureVisible(adminKey(key));
              await flush(tester);
              expect(
                tester.getSize(adminKey(key)).height,
                greaterThanOrEqualTo(48),
              );
            }
            await capture(tester, h, 'grants-form-$locale-${width.toInt()}-2x');
            await adminPress(tester, 'resource-grants-save');
            expect(h.puts.length, 1);
            expect(h.grants['3' * 32], {'read': true, 'write': true});
            expect(tester.takeException(), isNull);
            expect(h.haReads, 0);
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }
}
