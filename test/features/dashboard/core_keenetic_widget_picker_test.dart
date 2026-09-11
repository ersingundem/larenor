import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/keenetic/core/data/core_keenetic_dashboard_providers.dart';
import 'package:larenor/features/keenetic/core/presentation/core_keenetic_widget_picker_screen.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

final contextId = ServerContext.fromJson({
  'schemaVersion': 1,
  'coreId': '1' * 32,
  'homeId': '2' * 32,
});
final resource = HomeResourceRecord.fromJson({
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
}, expectedContext: contextId);
final draft = TileConfig(
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
  for (final type in [
    TileType.coreKeenetic,
    TileType.coreKeeneticDetails,
    TileType.coreKeeneticMesh,
    TileType.coreKeeneticClients,
    TileType.coreKeeneticBandwidth,
  ]) {
    testWidgets('tablet picker returns verified ${type.name} draft', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1180, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final results = <TileConfig>[];
      final expected = draft.copyWith(type: type);
      final container = ProviderContainer(
        overrides: [
          coreKeeneticDashboardResourcesProvider.overrideWith(
            (_) async => [resource],
          ),
          coreKeeneticDashboardDraftProvider.overrideWith((_, target) async {
            expect(identical(target, resource), isTrue);
            return expected;
          }),
          coreKeeneticDashboardVariantDraftProvider.overrideWith((
            _,
            selection,
          ) async {
            expect(identical(selection.target, resource), isTrue);
            expect(selection.type, type);
            return expected;
          }),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: CupertinoApp(
            locale: const Locale('en'),
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
                    final value = await Navigator.of(context).push<TileConfig>(
                      CupertinoPageRoute(
                        builder: (_) =>
                            CoreKeeneticWidgetPickerScreen(tileType: type),
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
      final choice = find.byKey(ValueKey('core-keenetic-pick-${resource.id}'));
      expect(choice, findsOneWidget);
      expect(
        tester.widget<CupertinoButton>(choice).minimumSize,
        const Size(48, 48),
      );
      await tester.ensureVisible(choice);
      await tester.tap(choice);
      await tester.pumpAndSettle();
      expect(results, [expected]);
      expect(tester.takeException(), isNull);
    });
  }
}
