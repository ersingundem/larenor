import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/ha_tools/presentation/ha_tools_screen.dart';
import 'package:larenor/features/settings/presentation/panes/home_assistant_pane.dart';
import 'package:larenor/features/settings/presentation/panes/settings_nav_row.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

Future<void> _mount(
  WidgetTester tester, {
  required String language,
  required double width,
  AppInteractionController? interaction,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = interaction ?? AppInteractionController();
  if (interaction == null) addTearDown(controller.dispose);
  await tester.pumpWidget(
    ProviderScope(
      child: AppInteractionScope(
        controller: controller,
        child: CupertinoApp(
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const HomeAssistantPane(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets(
        '$language Home Assistant tools action is accessible at ${width}px 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          await _mount(tester, language: language, width: width);

          expect(find.byType(SettingsPaneScaffold), findsOneWidget);
          expect(find.byType(SettingsSection), findsNWidgets(2));
          expect(find.byType(SettingsActionTile), findsNWidgets(9));
          expect(
            tester
                .getSemantics(
                  find.byKey(const ValueKey('home-assistant-tools-header')),
                )
                .flagsCollection
                .isHeader,
            isTrue,
          );

          final tools = find.byKey(
            const ValueKey('home-assistant-tools-action'),
          );
          expect(tester.getRect(tools).height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(tools).flagsCollection.isButton, isTrue);
          Focus.of(
            tester.element(
              find.descendant(of: tools, matching: find.byType(Text)).first,
            ),
          ).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();

          expect(find.byType(HaToolsScreen), findsOneWidget);
          expect(tester.takeException(), isNull);
          semantics.dispose();
        },
      );
    }
  }

  testWidgets('captured Home Assistant navigation expires on idle', (
    tester,
  ) async {
    final interaction = AppInteractionController();
    addTearDown(interaction.dispose);
    await _mount(tester, language: 'en', width: 1200, interaction: interaction);
    final action = find.byKey(const ValueKey('home-assistant-tools-action'));
    final button = find.descendant(
      of: action,
      matching: find.byType(CupertinoButton),
    );
    final stale = tester.widget<CupertinoButton>(button).onPressed!;
    interaction.setActive(false);
    interaction.setActive(true);
    await tester.pump();
    stale();
    await tester.pumpAndSettle();
    expect(find.byType(HaToolsScreen), findsNothing);
    tester.widget<CupertinoButton>(button).onPressed!();
    await tester.pumpAndSettle();
    expect(find.byType(HaToolsScreen), findsOneWidget);
  });
}
