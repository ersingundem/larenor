import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/admin/data/models/ha_registry_entry.dart';
import 'package:larenor/features/admin/presentation/entities_screen.dart';
import 'package:larenor/features/admin/providers/admin_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/service_root_scaffold.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

class _Registry extends EntityRegistry {
  static int builds = 0;

  @override
  Future<List<HaRegistryEntry>> build() async {
    builds++;
    return const [
      HaRegistryEntry(entityId: 'light.entry', originalName: 'Entry light'),
    ];
  }
}

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
      overrides: [entityRegistryProvider.overrideWith(_Registry.new)],
      child: CupertinoApp(
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const EntitiesScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets('$language entity refresh is accessible at ${width}px 2x', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        _Registry.builds = 0;
        await _mount(tester, language: language, width: width);

        expect(find.byType(ServiceRootScaffold), findsOneWidget);
        expect(find.byType(SettingsSection), findsNWidgets(2));
        expect(find.byType(SettingsActionTile), findsOneWidget);
        expect(
          tester
              .getSemantics(
                find.byKey(const ValueKey('entities-controls-header')),
              )
              .flagsCollection
              .isHeader,
          isTrue,
        );
        final refresh = find.byKey(const ValueKey('entities-refresh-action'));
        expect(
          tester.widget<CupertinoButton>(refresh).minimumSize,
          const Size(48, 48),
        );
        expect(tester.getSemantics(refresh).flagsCollection.isButton, isTrue);
        expect(
          tester
              .getSemantics(find.byKey(const ValueKey('entity-light.entry')))
              .rect
              .height,
          greaterThanOrEqualTo(48),
        );

        Focus.of(
          tester.element(
            find.descendant(of: refresh, matching: find.byType(Text)).first,
          ),
        ).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();

        expect(_Registry.builds, 2);
        expect(tester.takeException(), isNull);
        semantics.dispose();
      });
    }
  }
}
