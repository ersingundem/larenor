import 'dart:ui' as ui;
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

void main() {
  for (final language in ['en', 'tr']) {
    for (final brightness in Brightness.values) {
      for (final width in [600.0, 1200.0]) {
        for (final scale in [1.0, 2.0]) {
          testWidgets(
            'settings focus and names $language $brightness $width ${scale}x',
            (tester) async {
              final semantics = tester.ensureSemantics();
              tester.view.physicalSize = Size(width, 700);
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.reset);
              try {
                await tester.runAsync(() async {
                  final data = await rootBundle.load(
                    'assets/fonts/Inter-Variable.ttf',
                  );
                  for (final family in [
                    'Inter',
                    'CupertinoSystemText',
                    'CupertinoSystemDisplay',
                  ]) {
                    await (FontLoader(
                      family,
                    )..addFont(Future.value(data))).load();
                  }
                  await (FontLoader(
                        'packages/cupertino_icons/CupertinoIcons',
                      )..addFont(
                        rootBundle.load(
                          'packages/cupertino_icons/assets/CupertinoIcons.ttf',
                        ),
                      ))
                      .load();
                });
                final boundary = GlobalKey();
                final labels = language == 'en'
                    ? [
                        'Home Assistant connection',
                        'Unavailable',
                        'Screen settings',
                      ]
                    : [
                        'Home Assistant bağlantısı',
                        'Kullanılamıyor',
                        'Ekran ayarları',
                      ];
                final counts = [0, 0, 0];
                await tester.pumpWidget(
                  CupertinoApp(
                    theme: larenorTheme(brightness: brightness),
                    builder: (context, child) =>
                        RepaintBoundary(key: boundary, child: child!),
                    home: Builder(
                      builder: (context) => MediaQuery(
                        data: MediaQuery.of(context)
                            .copyWith(textScaler: TextScaler.linear(scale)),
                        child: CupertinoPageScaffold(
                          child: Center(
                            child: SettingsSection(
                              children: [
                                for (var i = 0; i < labels.length; i++)
                                  SettingsActionTile(
                                    title: Text(labels[i]),
                                    leading: i == 0
                                        ? const Icon(
                                            CupertinoIcons.house,
                                            semanticLabel: 'decorative icon',
                                          )
                                        : null,
                                    selected: i == 0 ? true : null,
                                    onTap: i == 1 ? null : () => counts[i]++,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
                await tester.pumpAndSettle();
                for (var i = 0; i < labels.length; i++) {
                  final node = tester.getSemantics(find.text(labels[i]));
                  expect(node.label, labels[i]);
                  expect(node.hasFlag(ui.SemanticsFlag.isButton), isTrue);
                  expect(node.hasFlag(ui.SemanticsFlag.isEnabled), i != 1);
                  expect(
                    node.getSemanticsData().hasAction(ui.SemanticsAction.tap),
                    i != 1,
                  );
                  expect(node.rect.height, greaterThanOrEqualTo(48));
                }
                expect(
                  tester
                      .getSemantics(find.text(labels[0]))
                      .hasFlag(ui.SemanticsFlag.isSelected),
                  isTrue,
                );
                Focus.of(tester.element(find.text(labels[0]))).requestFocus();
                await tester.pump();
                await tester.sendKeyEvent(LogicalKeyboardKey.tab);
                await tester.pump();
                expect(
                  Focus.of(tester.element(find.text(labels[2])))
                      .hasPrimaryFocus,
                  isTrue,
                );
                expect(counts, [0, 0, 0]);
                final decorationFinder = find.descendant(
                  of: find.widgetWithText(SettingsActionTile, labels[2]),
                  matching: find.byWidgetPredicate(
                    (widget) =>
                        widget is DecoratedBox &&
                        widget.decoration is ShapeDecoration &&
                        (widget.decoration as ShapeDecoration).shape
                            is OutlinedBorder &&
                        ((widget.decoration as ShapeDecoration).shape
                                    as OutlinedBorder)
                                .side
                                .width >
                            0,
                  ),
                );
                final decoration =
                    tester.widget<DecoratedBox>(decorationFinder).decoration
                        as ShapeDecoration;
                final side = (decoration.shape as OutlinedBorder).side;
                final context = tester.element(find.byType(SettingsSection));
                for (final background in [
                  CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
                    context,
                  ),
                  CupertinoColors.systemFill.resolveFrom(context),
                ]) {
                  final a = Color.alphaBlend(
                    side.color,
                    background,
                  ).computeLuminance();
                  final b = background.computeLuminance();
                  expect(
                    ((a > b ? a : b) + .05) / ((a > b ? b : a) + .05),
                    greaterThanOrEqualTo(3),
                  );
                }
                final ring = tester
                    .getRect(decorationFinder)
                    .inflate(side.width);
                final clip = tester.getRect(
                  find.byType(ClipRSuperellipse).last,
                );
                expect(ring.left, greaterThanOrEqualTo(clip.left));
                expect(ring.right, lessThanOrEqualTo(clip.right));
                expect(ring.top, greaterThanOrEqualTo(clip.top));
                expect(ring.bottom, lessThanOrEqualTo(clip.bottom));
                await _capture(
                  tester,
                  boundary,
                  '$language-${brightness.name}-${width.toInt()}-${scale.toInt()}x-last',
                );
                await tester.sendKeyEvent(LogicalKeyboardKey.space);
                await tester.pumpAndSettle();
                expect(counts, [0, 0, 1]);
                await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
                await tester.sendKeyEvent(LogicalKeyboardKey.tab);
                await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
                await tester.pump();
                expect(
                  Focus.of(tester.element(find.text(labels[0])))
                      .hasPrimaryFocus,
                  isTrue,
                );
                await _capture(
                  tester,
                  boundary,
                  '$language-${brightness.name}-${width.toInt()}-${scale.toInt()}x-first',
                );
                await tester.sendKeyEvent(LogicalKeyboardKey.enter);
                await tester.pumpAndSettle();
                expect(counts, [1, 0, 1]);
                final node = tester.getSemantics(find.text(labels[2]));
                node.owner!.performAction(node.id, ui.SemanticsAction.tap);
                await tester.pumpAndSettle();
                expect(counts, [1, 0, 2]);
                await tester.tap(find.text(labels[1]));
                await tester.pumpAndSettle();
                expect(counts, [1, 0, 2]);
                expect(tester.takeException(), isNull);
              } finally {
                await tester.pumpWidget(const SizedBox.shrink());
                await tester.pump();
                semantics.dispose();
              }
            },
          );
        }
      }
    }
  }
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  const directory = String.fromEnvironment('SETTINGS_PREVIEW_DIR');
  if (directory.isEmpty) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  await tester.runAsync(() async {
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
  });
}
