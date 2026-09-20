import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/settings/presentation/panes/security_pane.dart';
import 'package:larenor/features/settings/presentation/panes/settings_nav_row.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

Future<void> _mount(
  WidgetTester tester, {
  required String language,
  required double width,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: CupertinoApp(
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const SecurityPane(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets(
        '$language security PIN action is accessible at ${width}px 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          await _mount(tester, language: language, width: width);

          expect(find.byType(SettingsPaneScaffold), findsOneWidget);
          expect(find.byType(SettingsSection), findsOneWidget);
          expect(find.byType(SettingsActionTile), findsOneWidget);
          expect(
            tester
                .getSemantics(
                  find.byKey(const ValueKey('security-settings-header')),
                )
                .flagsCollection
                .isHeader,
            isTrue,
          );

          final pin = find.byKey(const ValueKey('security-pin-action'));
          expect(tester.getRect(pin).height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(pin).flagsCollection.isButton, isTrue);
          Focus.of(
            tester.element(
              find.descendant(of: pin, matching: find.byType(Text)).first,
            ),
          ).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();

          expect(find.byType(CupertinoAlertDialog), findsOneWidget);
          expect(find.byType(CupertinoTextField), findsOneWidget);
          expect(tester.takeException(), isNull);
          semantics.dispose();
        },
      );
    }
  }
}
