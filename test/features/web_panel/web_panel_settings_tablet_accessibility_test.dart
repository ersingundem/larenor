import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/web_panel/presentation/web_panel_settings_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/service_root_scaffold.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

const _tile = TileConfig(
  id: 'web',
  type: TileType.webview,
  x: 0,
  y: 0,
  width: 2,
  height: 2,
  url: 'https://panel.invalid',
);

Future<TileConfig? Function()> _mount(
  WidgetTester tester, {
  required String language,
  required double width,
}) async {
  TileConfig? saved;
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
        home: Builder(
          builder: (context) => CupertinoPageScaffold(
            child: Center(
              child: CupertinoButton(
                onPressed: () async {
                  saved = await Navigator.of(context).push<TileConfig>(
                    CupertinoPageRoute(
                      builder: (_) =>
                          const WebPanelSettingsScreen(initialTile: _tile),
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  return () => saved;
}

void main() {
  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets('$language web panel save is accessible at ${width}px 2x', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        final saved = await _mount(tester, language: language, width: width);

        expect(find.byType(ServiceRootScaffold), findsOneWidget);
        expect(find.byType(SettingsSection), findsAtLeast(1));
        expect(
          tester
              .getSemantics(
                find.byKey(const ValueKey('web-settings-content-header')),
              )
              .flagsCollection
              .isHeader,
          isTrue,
        );
        final save = find.byKey(const ValueKey('web-settings-save'));
        if (save.evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            save,
            200,
            scrollable: find
                .byWidgetPredicate(
                  (widget) =>
                      widget is Scrollable &&
                      widget.axisDirection == AxisDirection.down,
                )
                .first,
          );
        }
        await tester.ensureVisible(save);
        await tester.pumpAndSettle();
        expect(find.byType(SettingsActionTile), findsAtLeast(1));
        expect(
          tester.widget<CupertinoButton>(save).minimumSize,
          const Size(48, 48),
        );
        expect(tester.getSemantics(save).flagsCollection.isButton, isTrue);

        Focus.of(
          tester.element(
            find.descendant(of: save, matching: find.byType(Text)).first,
          ),
        ).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();

        expect(saved()?.url, 'https://panel.invalid');
        expect(find.byType(WebPanelSettingsScreen), findsNothing);
        expect(tester.takeException(), isNull);
        semantics.dispose();
      });
    }
  }
}
