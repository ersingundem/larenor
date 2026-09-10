import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import '../home_resources/home_resources_tablet_test.dart' show loadFonts;
import 'remote_profiles_ui_fixture.dart';

List<SemanticsNode> effective(WidgetTester t) {
  final result = <SemanticsNode>[];
  void visit(SemanticsNode node) {
    if (!node.isMergedIntoParent) result.add(node);
    node.visitChildren((n) {
      visit(n);
      return true;
    });
  }

  void owner(PipelineOwner pipeline) {
    final node = pipeline.semanticsOwner?.rootSemanticsNode;
    if (node != null) visit(node);
    pipeline.visitChildren(owner);
  }

  owner(t.binding.rootPipelineOwner);
  return result;
}

void target(WidgetTester t, String label) {
  final nodes = effective(t).where((n) {
    final d = n.getSemanticsData();
    return d.label == label &&
        d.flagsCollection.isButton &&
        d.hasAction(SemanticsAction.tap);
  }).toList();
  expect(nodes.length, 1);
  expect(nodes.single.rect.width, greaterThanOrEqualTo(48));
  expect(nodes.single.rect.height, greaterThanOrEqualTo(48));
}

Future<void> screenshot(WidgetTester t, RemoteUi h, String name) async {
  const directory = String.fromEnvironment('REMOTE_PROFILES_QA');
  if (directory.isEmpty) return;
  await t.runAsync(() async {
    final image =
        await (h.boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory(directory).createSync(recursive: true);
    File('$directory/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  for (final locale in ['en', 'tr']) {
    for (final width in [320.0, 600.0, 1280.0]) {
      testWidgets(
        '$locale $width 2x actual profile form semantics and native keyboard',
        (t) async {
          await loadFonts(t);
          final semantics = t.ensureSemantics();
          try {
            final h = RemoteUi();
            await h.mount(t, width: width, scale: 2, locale: locale);
            await h.edit(t, name: 'Ev sunucusu', host: '2001:db8::1');
            final l = AppLocalizations.of(t.element(key('remote-save')));
            await t.ensureVisible(key('remote-user'));
            await t.pumpAndSettle();
            await t.tap(key('remote-user'));
            await t.pumpAndSettle();
            t.testTextInput.hide();
            await t.sendKeyEvent(LogicalKeyboardKey.tab);
            await t.pumpAndSettle();
            final saveText = find
                .descendant(of: key('remote-save'), matching: find.byType(Text))
                .first;
            expect(Focus.of(t.element(saveText)).hasPrimaryFocus, isTrue);
            target(t, l.commonSave);
            final button = find.descendant(
              of: key('remote-save'),
              matching: find.byType(CupertinoButton),
            );
            final decorated = find
                .descendant(
                  of: button,
                  matching: find.byWidgetPredicate(
                    (w) =>
                        w is DecoratedBox &&
                        w.decoration is ShapeDecoration &&
                        (w.decoration as ShapeDecoration).shape
                            is OutlinedBorder,
                  ),
                )
                .first;
            final shape =
                (t.widget<DecoratedBox>(decorated).decoration
                            as ShapeDecoration)
                        .shape
                    as OutlinedBorder;
            expect(shape.side.width, greaterThan(0));
            final ring = t.getRect(decorated).inflate(shape.side.strokeOutset);
            expect(ring.top, greaterThanOrEqualTo(0));
            expect(ring.bottom, lessThanOrEqualTo(1100));
            await t.sendKeyEvent(LogicalKeyboardKey.tab);
            await t.pumpAndSettle();
            target(t, l.commonCancel);
            await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
            await t.sendKeyEvent(LogicalKeyboardKey.tab);
            await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
            await t.pumpAndSettle();
            expect(Focus.of(t.element(saveText)).hasPrimaryFocus, isTrue);
            await screenshot(t, h, 'remote-$locale-${width.toInt()}-2x');
            await t.sendKeyEvent(LogicalKeyboardKey.space);
            await t.pumpAndSettle();
            expect(h.writes, 1);
            await h.openFirst(t);
            await press(t, 'remote-delete');
            final cancelText = find
                .descendant(
                  of: key('remote-delete-cancel'),
                  matching: find.byType(Text),
                )
                .first;
            await t.ensureVisible(cancelText);
            await t.pumpAndSettle();
            Focus.of(t.element(cancelText)).requestFocus();
            await t.pump();
            await t.sendKeyEvent(LogicalKeyboardKey.enter);
            await t.pumpAndSettle();
            expect(h.writes, 1);
            expect(key('remote-delete-confirm'), findsNothing);
            expect(t.takeException(), isNull);
            await t.pumpWidget(const SizedBox());
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }
}
