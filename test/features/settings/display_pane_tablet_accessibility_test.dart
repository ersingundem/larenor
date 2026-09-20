import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(child: _LocalizedDisplayPane(language: language)),
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
          semantics.dispose();
        },
      );
    }
  }
}
