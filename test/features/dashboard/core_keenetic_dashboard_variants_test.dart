import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/domain/core_keenetic_tile_validation.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout_validation.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/dashboard/presentation/tiles/core_keenetic_tile.dart';
import 'package:larenor/features/dashboard/presentation/tiles/tile_registry.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/keenetic/core/domain/core_keenetic_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const _core = '11111111111111111111111111111111';
const _home = '22222222222222222222222222222222';
const _resource = '33333333333333333333333333333333';
const _binding = '44444444444444444444444444444444';
const _service = '55555555555555555555555555555555';

final _context = ServerContext.fromJson({
  'schemaVersion': 1,
  'coreId': _core,
  'homeId': _home,
});
final _target = HomeResourceRecord.fromJson({
  'ref': {
    'schemaVersion': 1,
    'coreId': _core,
    'homeId': _home,
    'kind': 'resource',
    'id': _resource,
  },
  'label': 'Main router',
  'order': 0,
  'revision': 7,
  'aclRevision': 9,
  'permissions': {'read': true, 'write': false},
}, expectedContext: _context);

TileConfig _tile(TileType type) => TileConfig(
  id: type.name,
  type: type,
  x: 0,
  y: 0,
  width: 3,
  height: 2,
  title: 'Main router',
  coreId: _core,
  coreHomeId: _home,
  coreResourceId: _resource,
  coreResourceRevision: 7,
  coreResourceAclRevision: 9,
  coreBindingId: _binding,
  coreBindingRevision: 4,
);

CoreKeeneticDetailsPage _details() => CoreKeeneticDetailsPage.fromJson({
  'entries': [
    {
      'kind': 'interface',
      'id': 'WifiMaster0',
      'name': 'Home Wi-Fi',
      'interfaceKind': 'wifi',
      'online': true,
      'address': '192.0.2.1',
      'rxBytes': 1024,
      'txBytes': 2048,
      'guest': false,
      'ssid': 'Larenor Home',
      'band': '5',
      'channel': 36,
      'signalDbm': -42,
    },
    {
      'kind': 'client',
      'id': '0123456789abcdef',
      'name': 'Living room TV',
      'ipAddress': '192.0.2.20',
      'macHash': '0123456789abcdef',
      'interfaceId': 'WifiMaster0',
      'online': true,
      'registered': true,
      'internetAccess': 'allowed',
      'band': '5',
      'signalDbm': -51,
    },
  ],
  'snapshot': 'a' * 64,
  'nextAfter': null,
});

CoreKeeneticTopologySnapshot _topology() =>
    CoreKeeneticTopologySnapshot.fromJson({
      'ref': {
        'schemaVersion': 1,
        'coreId': _core,
        'homeId': _home,
        'kind': 'resource',
        'id': _resource,
      },
      'bindingId': _binding,
      'bindingRevision': 4,
      'serviceId': _service,
      'serviceRevision': 3,
      'resourceRevision': 7,
      'aclRevision': 9,
      'observedAt': '2026-09-11T08:00:00Z',
      'remainingTtlMs': 5000,
      'nodes': [
        {
          'id': '1111111111111111',
          'name': 'Main router',
          'model': 'Keenetic',
          'role': 'controller',
          'online': true,
          'parentId': null,
          'backhaulType': null,
          'backhaulQuality': null,
          'pathCost': null,
        },
        {
          'id': '2222222222222222',
          'name': 'Hall extender',
          'model': 'Buddy',
          'role': 'extender',
          'online': true,
          'parentId': '1111111111111111',
          'backhaulType': 'wifi_5',
          'backhaulQuality': 'good',
          'pathCost': 60,
        },
      ],
      'networks': [
        {
          'id': 'WifiMaster0',
          'ssid': 'Larenor Home',
          'band': '5',
          'channel': 36,
          'clientCount': 4,
          'online': true,
        },
      ],
    }, target: _target);

void main() {
  const variants = {
    TileType.coreKeenetic,
    TileType.coreKeeneticDetails,
    TileType.coreKeeneticMesh,
  };

  test('all Core Keenetic card variants persist the sealed authority tuple', () {
    for (final type in variants) {
      final tile = _tile(type);
      final raw = DashboardLayout(tiles: [tile]).toJson();
      validateDashboardLayoutJson(raw);
      expect(hasValidCoreKeeneticTileFields(tile.toJson()), isTrue);
      expect(DashboardLayout.fromJson(raw).tiles.single, tile);
    }
  });

  test('registry exposes distinct internet, details and mesh cards', () {
    expect(buildTileContent(_tile(TileType.coreKeenetic)), isA<CoreKeeneticTile>());
    expect(
      buildTileContent(_tile(TileType.coreKeeneticDetails)),
      isA<CoreKeeneticDetailsTile>(),
    );
    expect(
      buildTileContent(_tile(TileType.coreKeeneticMesh)),
      isA<CoreKeeneticMeshTile>(),
    );
  });

  for (final size in [const Size(600, 900), const Size(1280, 900)]) {
    testWidgets('details and mesh cards fit ${size.width} at 2x text', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
            ),
            child: child!,
          ),
          home: CupertinoPageScaffold(
            child: Column(
              children: [
                Expanded(
                  child: CoreKeeneticDetailsDashboardCard(
                    title: 'Network devices',
                    page: _details(),
                    failure: null,
                    stale: false,
                    loading: false,
                    onRefresh: () {},
                  ),
                ),
                Expanded(
                  child: CoreKeeneticTopologyDashboardCard(
                    title: 'Mesh topology',
                    topology: _topology(),
                    failure: null,
                    stale: false,
                    loading: false,
                    onRefresh: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Living room TV'), findsOneWidget);
      expect(find.text('Hall extender'), findsOneWidget);
      for (final key in [
        'core-keenetic-details-refresh',
        'core-keenetic-mesh-refresh',
      ]) {
        final button = tester.widget<CupertinoButton>(find.byKey(ValueKey(key)));
        expect(button.minimumSize?.height, greaterThanOrEqualTo(48));
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('stale and offline cards stay visible and refreshable', (
    tester,
  ) async {
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CupertinoPageScaffold(
          child: Column(
            children: [
              Expanded(
                child: CoreKeeneticDetailsDashboardCard(
                  title: 'Devices',
                  page: null,
                  failure: 'connection_failed',
                  stale: false,
                  loading: false,
                  onRefresh: () {},
                ),
              ),
              Expanded(
                child: CoreKeeneticTopologyDashboardCard(
                  title: 'Mesh',
                  topology: _topology(),
                  failure: null,
                  stale: true,
                  loading: false,
                  onRefresh: () {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('Data is stale'), findsOneWidget);
    expect(find.byKey(const ValueKey('core-keenetic-details-refresh')), findsOneWidget);
    expect(find.byKey(const ValueKey('core-keenetic-mesh-refresh')), findsOneWidget);
  });
}
