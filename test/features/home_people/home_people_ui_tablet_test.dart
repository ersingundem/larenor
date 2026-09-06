import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import '../../core/home_scope_fixture.dart' show flush;
import '../home_resources/home_resources_tablet_test.dart' show loadFonts;
import 'home_people_ui_fixture.dart';
import 'home_people_ui_test.dart' show key, press, reveal, openPeople;

Future<void> button(
  WidgetTester tester,
  String id,
  String label,
  double width,
) async {
  await reveal(tester, key(id));
  final native = find.descendant(
    of: key(id),
    matching: find.byType(CupertinoButton),
  );
  expect(native, findsOneWidget);
  final node = tester.getSemantics(native);
  expect(node.label, label);
  expect(node.flagsCollection.isButton, isTrue);
  expect(node.flagsCollection.isHeader, isFalse);
  expect(node.rect.height, greaterThanOrEqualTo(48));
  expect(node.rect.width, greaterThanOrEqualTo(48));
  expect(find.bySemanticsLabel(label), findsOneWidget);
  final rect = tester.getRect(native);
  expect(rect.left, greaterThanOrEqualTo(0));
  expect(rect.right, lessThanOrEqualTo(width));
  expect(tester.takeException(), isNull);
}

Future<void> focus(WidgetTester tester, String id) async {
  await reveal(tester, key(id));
  final text = find.descendant(of: key(id), matching: find.byType(Text));
  Focus.of(tester.element(text)).requestFocus();
  await flush(tester);
  expect(Focus.of(tester.element(text)).hasPrimaryFocus, isTrue);
}

Future<void> preview(
  WidgetTester tester,
  PeopleUiHarness h,
  String name,
) async {
  const output = String.fromEnvironment('HOME_PEOPLE_PREVIEW_DIR');
  if (output.isEmpty) return;
  await tester.runAsync(() async {
    final render =
            h.boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary,
        picture = await render.toImage(pixelRatio: 1);
    try {
      final png = await picture.toByteData(format: ui.ImageByteFormat.png);
      Directory(output).createSync(recursive: true);
      File('$output/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    } finally {
      picture.dispose();
    }
  });
}

void main() {
  testWidgets('actual page back focus outline stays inside the visible window', (tester)async{
    await loadFonts(tester);final h=PeopleUiHarness();await openPeople(tester,h,width:320,scale:2);await tester.sendKeyEvent(LogicalKeyboardKey.tab);await focus(tester,'home-people-back');
    final decoration=find.descendant(of:key('home-people-back'),matching:find.byWidgetPredicate((w)=>w is DecoratedBox&&w.decoration is ShapeDecoration&&(w.decoration as ShapeDecoration).shape is OutlinedBorder)).first;
    final outline=(tester.widget<DecoratedBox>(decoration).decoration as ShapeDecoration).shape as OutlinedBorder;final rect=tester.getRect(decoration);expect(outline.side.width,greaterThan(0));expect(rect.left-outline.side.strokeOutset,greaterThanOrEqualTo(0));expect(rect.top-outline.side.strokeOutset,greaterThanOrEqualTo(0));
  });
  for (final locale in ['en', 'tr']) {
    for (final width in [320.0, 600.0, 1280.0]) {
      for (final dark in [false, true]) {
        testWidgets(
          'actual people UI $locale $width ${dark ? 'dark' : 'light'} 2x real-font keyboard and concrete cancel',
          (tester) async {
            await loadFonts(tester);
            final semantics = tester.ensureSemantics();
            try {
              tester.platformDispatcher.platformBrightnessTestValue = dark
                  ? Brightness.dark
                  : Brightness.light;
              addTearDown(
                tester.platformDispatcher.clearPlatformBrightnessTestValue,
              );
              final h = PeopleUiHarness();
              await openPeople(
                tester,
                h,
                pin: '1234',
                locale: locale,
                width: width,
                scale: 2,
              );
              final l = AppLocalizations.of(
                tester.element(key('home-people-list')),
              );
              expect(
                tester
                    .getSemantics(find.text(l.homePeopleTitle))
                    .flagsCollection
                    .isHeader,
                isTrue,
              );
              await button(
                tester,
                'home-people-manage',
                l.homePeopleManage,
                width,
              );
              await press(tester, 'home-people-manage');
              await tester.enterText(find.byType(CupertinoTextField), '1234');
              await tester.testTextInput.receiveAction(TextInputAction.done);
              await flush(tester);
              final last = key('home-people-row-${'2' * 32}');
              await reveal(tester, last);
              expect(find.text(h.people[1]['label'] as String), findsOneWidget);
              expect(tester.takeException(), isNull);
              final id = '1' * 32;
              await button(
                tester,
                'home-people-edit-$id',
                l.homePeopleEditPerson('Deniz Öztürk'),
                width,
              );
              await focus(tester, 'home-people-edit-$id');
              await preview(tester,h,'people-list-$locale-${width.toInt()}-2x-${dark?'dark':'light'}');
              await tester.sendKeyEvent(LogicalKeyboardKey.tab);
              await flush(tester);
              expect(
                Focus.of(
                  tester.element(
                    find.descendant(
                      of: key('home-people-grants-$id'),
                      matching: find.byType(Text),
                    ),
                  ),
                ).hasPrimaryFocus,
                isTrue,
              );
              await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
              await tester.sendKeyEvent(LogicalKeyboardKey.tab);
              await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
              await flush(tester);
              expect(
                Focus.of(
                  tester.element(
                    find.descendant(
                      of: key('home-people-edit-$id'),
                      matching: find.byType(Text),
                    ),
                  ),
                ).hasPrimaryFocus,
                isTrue,
              );
              await tester.sendKeyEvent(LogicalKeyboardKey.enter);
              await flush(tester);
              expect(key('home-people-label'), findsOneWidget);
              final fieldNode = tester.getSemantics(key('home-people-label'));
              expect(fieldNode.label, l.homePeopleLabel);
              expect(fieldNode.flagsCollection.isTextField, isTrue);
              expect(
                tester.getSize(key('home-people-label')).height,
                greaterThanOrEqualTo(48),
              );
              await button(
                tester,
                'home-people-cancel-edit',
                l.commonCancel,
                width,
              );
              await focus(tester, 'home-people-cancel-edit');
              await tester.sendKeyEvent(LogicalKeyboardKey.space);
              await flush(tester);
              expect(h.writes, isEmpty);
              await press(tester, 'home-people-delete-$id');
              expect(key('home-people-delete-confirmation'), findsOneWidget);
              expect(find.text('Deniz Öztürk'), findsOneWidget);
              await button(
                tester,
                'home-people-confirm-delete',
                l.commonDelete,
                width,
              );
              await button(
                tester,
                'home-people-cancel-edit',
                l.commonCancel,
                width,
              );
              await focus(tester, 'home-people-confirm-delete');
              await tester.sendKeyEvent(LogicalKeyboardKey.tab);
              await flush(tester);
              expect(
                Focus.of(
                  tester.element(
                    find.descendant(
                      of: key('home-people-cancel-edit'),
                      matching: find.byType(Text),
                    ),
                  ),
                ).hasPrimaryFocus,
                isTrue,
              );
              await tester.sendKeyEvent(LogicalKeyboardKey.enter);
              await flush(tester);
              expect(h.writes, isEmpty);
              await press(tester, 'home-people-grants-$id');
              await button(
                tester,
                'home-people-user-${h.peopleContract['subjectId']}',
                'Member\n${l.homePeopleNoAccess}',
                width,
              );
              await press(
                tester,
                'home-people-user-${h.peopleContract['subjectId']}',
              );
              await button(
                tester,
                'home-people-permission-readOnly',
                l.homePeopleReadOnly,
                width,
              );
              expect(
                tester
                    .getSemantics(key('home-people-permission-readOnly'))
                    .flagsCollection
                    .isSelected,
                ui.Tristate.isTrue,
              );
              await button(
                tester,
                'home-people-permission-readWrite',
                l.homePeopleReadWrite,
                width,
              );
              await focus(tester, 'home-people-permission-readWrite');
              await tester.sendKeyEvent(LogicalKeyboardKey.space);
              await flush(tester);
              expect(
                tester
                    .getSemantics(key('home-people-permission-readWrite'))
                    .flagsCollection
                    .isSelected,
                ui.Tristate.isTrue,
              );
              expect(
                tester
                    .getSemantics(key('home-people-permission-readOnly'))
                    .flagsCollection
                    .isSelected,
                ui.Tristate.isFalse,
              );
              expect(h.writes, isEmpty);
              final outlines = find.descendant(
                of: key('home-people-permission-readWrite'),
                matching: find.byWidgetPredicate(
                  (w) =>
                      w is DecoratedBox &&
                      w.decoration is ShapeDecoration &&
                      (w.decoration as ShapeDecoration).shape is OutlinedBorder,
                ),
              );
              final outline =
                  ((tester.widget<DecoratedBox>(outlines.first).decoration
                              as ShapeDecoration)
                          .shape
                      as OutlinedBorder);
              expect(outline.side.width,greaterThan(0));
              final background = CupertinoTheme.of(
                tester.element(key('home-people-permission-readWrite')),
              ).scaffoldBackgroundColor;
              final a = outline.side.color.computeLuminance(),
                  b = background.computeLuminance();
              expect(
                ((a > b ? a : b) + .05) / ((a < b ? a : b) + .05),
                greaterThanOrEqualTo(3),
              );
              await preview(
                tester,
                h,
                'people-grants-$locale-${width.toInt()}-2x-${dark ? 'dark' : 'light'}',
              );
              await press(tester, 'home-people-permission-none');
              await press(tester, 'home-people-grant-save');
              expect(key('home-people-revoke-confirmation'), findsOneWidget);
              await button(
                tester,
                'home-people-confirm-revoke',
                l.homePeopleRevoke,
                width,
              );
              await button(
                tester,
                'home-people-grant-cancel',
                l.commonCancel,
                width,
              );
              await focus(tester, 'home-people-confirm-revoke');
              await tester.sendKeyEvent(LogicalKeyboardKey.tab);
              await flush(tester);
              expect(
                Focus.of(
                  tester.element(
                    find.descendant(
                      of: key('home-people-grant-cancel'),
                      matching: find.byType(Text),
                    ),
                  ),
                ).hasPrimaryFocus,
                isTrue,
              );
              await tester.sendKeyEvent(LogicalKeyboardKey.enter);
              await flush(tester);
              expect(h.writes, isEmpty);
              expect(h.haReads, 0);
              expect(tester.takeException(), isNull);
            } finally {
              semantics.dispose();
            }
          },
        );
      }
    }
  }
}
