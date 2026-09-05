import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/app_navigation_bar.dart';
import 'package:larenor/shared/theme/app_colors.dart';

void main() {
  for (final locale in ['en', 'tr']) {
    for (final brightness in Brightness.values) {
      for (final width in [320.0, 800.0]) {
        for (final scale in [1.0, 2.0]) {
          testWidgets(
            '$locale $brightness ${width}px ${scale}x touch and keyboard',
            (tester) async {
              final semantics = tester.ensureSemantics();
              try {
                tester.view.physicalSize = Size(width, 360);
                tester.view.devicePixelRatio = 1;
                addTearDown(tester.view.reset);
                var selected = 0;
                late List<String> labels;
                await tester.pumpWidget(
                  CupertinoApp(
                    theme: larenorTheme(brightness: brightness),
                    locale: Locale(locale),
                    localizationsDelegates:
                        AppLocalizations.localizationsDelegates,
                    supportedLocales: AppLocalizations.supportedLocales,
                    home: Builder(
                      builder: (context) {
                        final l10n = AppLocalizations.of(context);
                        labels = [
                          l10n.navigationHome,
                          l10n.navigationMedia,
                          l10n.navigationRoutines,
                          l10n.navigationSystem,
                        ];
                        return MediaQuery(
                          data: MediaQuery.of(context).copyWith(
                            textScaler: TextScaler.linear(scale),
                            padding: const EdgeInsets.fromLTRB(12, 20, 12, 16),
                          ),
                          child: CupertinoPageScaffold(
                            child: Column(
                              children: [
                                const Expanded(child: SizedBox.shrink()),
                                StatefulBuilder(
                                  builder: (context, update) =>
                                      AppNavigationBar(
                                        currentIndex: selected,
                                        onTap: (index) =>
                                            update(() => selected = index),
                                        items: [
                                          for (final label in labels)
                                            BottomNavigationBarItem(
                                              icon: const Icon(
                                                CupertinoIcons.house,
                                              ),
                                              label: label,
                                            ),
                                        ],
                                      ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                );
                await tester.pumpAndSettle();
                for (var i = 0; i < labels.length; i++) {
                  final button = find.byKey(ValueKey('root-navigation-$i'));
                  final rect = tester.getRect(button);
                  expect(rect.width, greaterThanOrEqualTo(48));
                  expect(rect.height, greaterThanOrEqualTo(48));
                  expect(rect.left, greaterThanOrEqualTo(12));
                  expect(rect.right, lessThanOrEqualTo(width - 12));
                  expect(rect.bottom, lessThanOrEqualTo(344));
                  expect(
                    tester.getSemantics(button),
                    isSemantics(
                      label: labels[i],
                      isButton: true,
                      isSelected: i == 0,
                      hasTapAction: true,
                      isFocusable: true,
                    ),
                  );
                  final labelRect = tester.getRect(find.text(labels[i]));
                  final iconRect = tester.getRect(
                    find.descendant(of: button, matching: find.byType(Icon)),
                  );
                  expect(
                    iconRect.bottom + 4,
                    lessThanOrEqualTo(labelRect.top + .01),
                  );
                  expect(labelRect.bottom, lessThanOrEqualTo(rect.bottom));
                }
                await expectLater(
                  tester,
                  meetsGuideline(androidTapTargetGuideline),
                );
                // Tab advances without activating a destination; Space activates
                // exactly the newly focused control through framework Actions.
                Focus.of(tester.element(find.text(labels[0]))).requestFocus();
                await tester.pump();
                await tester.sendKeyEvent(LogicalKeyboardKey.tab);
                await tester.pump();
                expect(selected, 0);
                expect(
                  Focus.of(tester.element(find.text(labels[1])))
                      .hasPrimaryFocus,
                  isTrue,
                );
                final outline = tester.widget<DecoratedBox>(
                  find.descendant(
                    of: find.byKey(const ValueKey('root-navigation-1')),
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
                  ),
                );
                final color =
                    ((outline.decoration as ShapeDecoration).shape
                            as OutlinedBorder)
                        .side
                        .color;
                final context = tester.element(find.byType(AppNavigationBar));
                for (final background in [
                  AppColors.navigation.resolveFrom(context),
                  AppColors.surface.resolveFrom(context),
                ]) {
                  final a = Color.alphaBlend(
                    color,
                    background,
                  ).computeLuminance();
                  final b = background.computeLuminance();
                  final contrast =
                      ((a > b ? a : b) + .05) / ((a > b ? b : a) + .05);
                  expect(
                    contrast,
                    greaterThanOrEqualTo(3),
                    reason: 'Visible keyboard focus',
                  );
                }
                await tester.sendKeyEvent(LogicalKeyboardKey.space);
                await tester.pumpAndSettle();
                expect(selected, 1);
                expect(
                  tester.getSemantics(
                    find.byKey(const ValueKey('root-navigation-1')),
                  ),
                  isSemantics(label: labels[1], isSelected: true),
                );
                for (final index in [2, 3]) {
                  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
                  await tester.pump();
                  expect(
                    Focus.of(tester.element(find.text(labels[index])))
                        .hasPrimaryFocus,
                    isTrue,
                  );
                  expect(selected, 1);
                }
                await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
                await tester.sendKeyEvent(LogicalKeyboardKey.tab);
                await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
                await tester.pump();
                expect(
                  Focus.of(tester.element(find.text(labels[2])))
                      .hasPrimaryFocus,
                  isTrue,
                );
                await tester.tap(find.text(labels[3]));
                await tester.pumpAndSettle();
                expect(selected, 3);
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
}
