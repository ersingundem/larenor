import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/keenetic/core/data/core_keenetic_dashboard_providers.dart';
import 'package:larenor/features/keenetic/core/presentation/core_keenetic_widget_picker_screen.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/service_root_scaffold.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

final _context = ServerContext.fromJson({
  'schemaVersion': 1,
  'coreId': '1' * 32,
  'homeId': '2' * 32,
});
final _resource = HomeResourceRecord.fromJson({
  'ref': {
    'schemaVersion': 1,
    'coreId': '1' * 32,
    'homeId': '2' * 32,
    'kind': 'resource',
    'id': '3' * 32,
  },
  'label': 'Main router',
  'order': 0,
  'revision': 7,
  'aclRevision': 9,
  'permissions': {'read': true, 'write': false},
}, expectedContext: _context);
final _draft = TileConfig(
  id: 'core-router',
  type: TileType.coreKeenetic,
  x: 0,
  y: 0,
  width: 3,
  height: 2,
  title: 'Main router',
  coreId: '1' * 32,
  coreHomeId: '2' * 32,
  coreResourceId: '3' * 32,
  coreResourceRevision: 7,
  coreResourceAclRevision: 9,
  coreBindingId: '4' * 32,
  coreBindingRevision: 4,
);

void main() {
  for (final language in ['en', 'tr']) {
    for (final size in [const Size(600, 900), const Size(1200, 900)]) {
      testWidgets(
        '$language Core Keenetic picker is accessible at ${size.width}px 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final results = <TileConfig>[];
          final container = ProviderContainer(
            overrides: [
              coreKeeneticDashboardResourcesProvider.overrideWith(
                (_) async => [_resource],
              ),
              coreKeeneticDashboardDraftProvider.overrideWith((
                _,
                target,
              ) async {
                expect(identical(target, _resource), isTrue);
                return _draft;
              }),
            ],
          );
          addTearDown(container.dispose);
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
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
                    child: CupertinoButton(
                      child: const Text('Open'),
                      onPressed: () async {
                        final value = await Navigator.of(context)
                            .push<TileConfig>(
                              CupertinoPageRoute(
                                builder: (_) =>
                                    const CoreKeeneticWidgetPickerScreen(),
                              ),
                            );
                        if (value != null) results.add(value);
                      },
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();

          expect(find.byType(ServiceRootScaffold), findsOneWidget);
          expect(find.byType(SettingsSection), findsOneWidget);
          expect(find.byType(SettingsActionTile), findsOneWidget);
          expect(
            tester
                .getSemantics(
                  find.byKey(const ValueKey('core-keenetic-picker-header')),
                )
                .flagsCollection
                .isHeader,
            isTrue,
          );

          final choice = find.byKey(
            ValueKey('core-keenetic-pick-${_resource.id}'),
          );
          expect(
            tester.widget<CupertinoButton>(choice).minimumSize,
            const Size(48, 48),
          );
          expect(tester.getRect(choice).height, closeTo(48, .01));
          expect(tester.getSemantics(choice).flagsCollection.isButton, isTrue);
          Focus.of(
            tester.element(
              find.descendant(of: choice, matching: find.byType(Text)).first,
            ),
          ).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();

          expect(results, [_draft]);
          expect(tester.takeException(), isNull);
          semantics.dispose();
        },
      );
    }
  }
}
