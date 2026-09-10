import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/domain/core_keenetic_tile_validation.dart';
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
  coreId: _core,
  coreHomeId: _home,
  coreResourceId: _resource,
  coreResourceRevision: 7,
  coreResourceAclRevision: 9,
  coreBindingId: _binding,
  coreBindingRevision: 4,
);

CoreKeeneticSnapshot _snapshot() => CoreKeeneticSnapshot.fromJson({
  'ref': {
    'schemaVersion': 1,
    'coreId': _core,
    'homeId': _home,
    'kind': 'resource',
    'id': _resource,
  },
  'bindingId': _binding,
  'bindingRevision': 4,
  'serviceId': '5' * 32,
  'serviceRevision': 3,
  'resourceRevision': 7,
  'aclRevision': 9,
  'observedAt': '2026-09-11T08:00:00Z',
  'remainingTtlMs': 5000,
  'telemetry': {
    'status': {
      'online': true,
      'publicIp': '198.51.100.20',
      'uptimeSeconds': 86400,
      'firmware': '4.3.6',
      'firmwareRevision': 44,
      'statusRevision': 71,
      'cpuPercent': 17.5,
      'memoryPercent': 42.0,
    },
    'interfaces': [
      {
        'id': 'WifiMaster0',
        'name': 'Home Wi-Fi',
        'kind': 'wifi',
        'online': true,
        'address': '192.0.2.1',
        'rxBytes': 1200,
        'txBytes': 500,
        'guest': false,
        'ssid': 'Larenor Home',
        'band': '5',
        'channel': 36,
        'signalDbm': -42,
      },
    ],
    'traffic': {
      'rxBytes': 734003200,
      'txBytes': 209715200,
      'downloadBps': 9000000,
      'uploadBps': 3000000,
    },
    'hosts': [
      {
        'id': 'host-1',
        'name': 'Tablet',
        'ipAddress': '192.0.2.20',
        'macAddress': '02:00:00:00:00:01',
        'interfaceId': 'WifiMaster0',
        'online': true,
        'registered': true,
        'internetAccess': 'allowed',
        'band': '5',
        'signalDbm': -51,
      },
    ],
  },
}, target: _target);

void main() {
  test(
    'client and bandwidth cards persist only a sealed Core authority tuple',
    () {
      for (final type in [
        TileType.coreKeeneticClients,
        TileType.coreKeeneticBandwidth,
      ]) {
        final tile = _tile(type);
        expect(hasValidCoreKeeneticTileFields(tile.toJson()), isTrue);
        expect(
          buildTileContent(tile),
          type == TileType.coreKeeneticClients
              ? isA<CoreKeeneticClientsTile>()
              : isA<CoreKeeneticBandwidthTile>(),
        );
      }
    },
  );

  for (final width in [600.0, 1280.0]) {
    testWidgets('private client and bandwidth cards fit $width at 2x', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      var refreshes = 0;
      await tester.pumpWidget(
        CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: CupertinoPageScaffold(
            child: Column(
              children: [
                Expanded(
                  child: CoreKeeneticClientsDashboardCard(
                    title: 'Connected devices',
                    snapshot: _snapshot(),
                    failure: null,
                    stale: false,
                    loading: false,
                    onRefresh: () => refreshes++,
                  ),
                ),
                Expanded(
                  child: CoreKeeneticBandwidthDashboardCard(
                    title: 'Bandwidth',
                    snapshot: _snapshot(),
                    failure: null,
                    stale: false,
                    loading: false,
                    onRefresh: () => refreshes++,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Tablet'), findsOneWidget);
      expect(find.textContaining('5 GHz'), findsOneWidget);
      expect(find.textContaining('-51 dBm'), findsOneWidget);
      expect(find.text('192.0.2.20'), findsNothing);
      expect(find.textContaining('02:00:00'), findsNothing);
      expect(find.textContaining('9.0 MB/s'), findsOneWidget);
      expect(find.textContaining('3.0 MB/s'), findsOneWidget);
      for (final key in [
        'core-keenetic-clients-refresh',
        'core-keenetic-bandwidth-refresh',
      ]) {
        expect(
          tester.widget<CupertinoButton>(find.byKey(ValueKey(key))).minimumSize,
          const Size.square(48),
        );
      }
      expect(
        tester
            .getSemantics(
              find.byKey(const ValueKey('core-keenetic-clients-card')),
            )
            .label,
        contains('Connected devices'),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(refreshes, 1);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }
}
