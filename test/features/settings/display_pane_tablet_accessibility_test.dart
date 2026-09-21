import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/multi_display/presentation/dual_display_route.dart';
import 'package:larenor/features/settings/presentation/panes/display_pane.dart';
import 'package:larenor/features/settings/presentation/panes/settings_nav_row.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/shared/widgets/settings_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _mount(
  WidgetTester tester, {
  required String language,
  required double width,
  AppInteractionController? interaction,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: interaction == null
          ? _LocalizedDisplayPane(language: language)
          : AppInteractionScope(
              controller: interaction,
              child: _LocalizedDisplayPane(language: language),
            ),
    ),
  );
  await tester.pumpAndSettle();
}

class _LocalizedDisplayPane extends StatelessWidget {
  const _LocalizedDisplayPane({required this.language});

  final String language;

  @override
  Widget build(BuildContext context) => CupertinoApp(
    locale: Locale(language),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: const TextScaler.linear(2)),
      child: child!,
    ),
    home: const DisplayPane(),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets(
        '$language display appearance action is accessible at ${width}px 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          await _mount(tester, language: language, width: width);

          expect(find.byType(SettingsPaneScaffold), findsOneWidget);
          expect(find.byType(SettingsSection), findsWidgets);
          expect(find.byType(SettingsActionTile), findsWidgets);
          expect(
            tester
                .getSemantics(
                  find.byKey(const ValueKey('display-settings-header')),
                )
                .flagsCollection
                .isHeader,
            isTrue,
          );

          final dualDisplay = find.byKey(
            const ValueKey('dual-display-settings-entry'),
          );
          await tester.scrollUntilVisible(
            dualDisplay,
            250,
            scrollable: find.byType(Scrollable).first,
          );
          expect(tester.getRect(dualDisplay).height, greaterThanOrEqualTo(48));
          expect(
            tester.getSemantics(dualDisplay).flagsCollection.isButton,
            isTrue,
          );
          Focus.of(
            tester.element(
              find
                  .descendant(of: dualDisplay, matching: find.byType(Text))
                  .first,
            ),
          ).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(find.byType(DualDisplayRoute), findsOneWidget);
          Navigator.of(tester.element(find.byType(DualDisplayRoute))).pop();
          await tester.pumpAndSettle();

          final appearance = find.byKey(
            const ValueKey('display-appearance-action'),
          );
          await tester.scrollUntilVisible(
            appearance,
            250,
            scrollable: find.byType(Scrollable).first,
          );
          expect(tester.getRect(appearance).height, greaterThanOrEqualTo(48));
          expect(
            tester.getSemantics(appearance).flagsCollection.isButton,
            isTrue,
          );
          Focus.of(
            tester.element(
              find
                  .descendant(of: appearance, matching: find.byType(Text))
                  .first,
            ),
          ).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();

          expect(find.byType(CupertinoActionSheet), findsOneWidget);
          expect(tester.takeException(), isNull);
          final keepScreenOn = find.byKey(
            const ValueKey('display-keep-screen-on'),
          );
          expect(tester.getRect(keepScreenOn).height, closeTo(48, .001));
          expect(
            tester.getSemantics(keepScreenOn).flagsCollection.isToggled,
            ui.Tristate.isFalse,
          );
          semantics.dispose();
        },
      );
    }
  }

  testWidgets('idle retires a captured display setting callback', (
    tester,
  ) async {
    final interaction = AppInteractionController();
    addTearDown(interaction.dispose);
    await _mount(tester, language: 'en', width: 600, interaction: interaction);
    final control = find.byKey(const ValueKey('display-keep-screen-on'));
    final stale = tester
        .widget<CupertinoSwitch>(
          find.descendant(of: control, matching: find.byType(CupertinoSwitch)),
        )
        .onChanged!;

    interaction.setActive(false);
    interaction.setActive(true);
    await tester.pump();
    stale(true);
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('keep_screen_on'), isNull);
    expect(
      tester.getSemantics(control).flagsCollection.isToggled,
      ui.Tristate.isFalse,
    );
  });
}
