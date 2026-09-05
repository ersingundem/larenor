import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/keenetic/data/keenetic_client.dart';
import 'package:larenor/features/keenetic/data/keenetic_config.dart';
import 'package:larenor/features/keenetic/data/keenetic_credentials_store.dart';
import 'package:larenor/features/keenetic/data/models/keenetic_access_point.dart';
import 'package:larenor/features/keenetic/data/models/keenetic_device.dart';
import 'package:larenor/features/keenetic/data/models/keenetic_router_status.dart';
import 'package:larenor/features/keenetic/presentation/keenetic_devices_screen.dart';
import 'package:larenor/features/keenetic/presentation/keenetic_home_screen.dart';
import 'package:larenor/features/keenetic/presentation/keenetic_wifi_screen.dart';
import 'package:larenor/features/keenetic/providers/keenetic_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const _config = KeeneticConfig(
  baseUrl: 'http://router.test',
  username: 'admin',
  password: 'example',
);

class _Credentials extends KeeneticCredentialsStore {
  @override
  Future<KeeneticConfig?> read() async => _config;
}

void main() {
  Widget app(Widget child) => CupertinoApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  );

  testWidgets('Wi-Fi cancel sends nothing and rejected changes show an error', (
    tester,
  ) async {
    var writes = 0;
    final client = KeeneticClient(
      config: _config,
      httpClient: MockClient((request) async {
        writes++;
        return http.Response(
          jsonEncode([
            {
              'parse': [
                {'status': 'error', 'message': 'Permission denied'},
              ],
            },
          ]),
          200,
        );
      }),
    );
    addTearDown(client.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keeneticCredentialsStoreProvider.overrideWithValue(_Credentials()),
          keeneticClientProvider.overrideWith((ref) async => client),
          keeneticAccessPointsProvider.overrideWith(
            (ref) async => const [
              KeeneticAccessPoint(
                id: 'WifiMaster0/AccessPoint0',
                name: 'Home',
                up: true,
              ),
            ],
          ),
        ],
        child: app(const KeeneticWifiScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CupertinoSwitch));
    await tester.pumpAndSettle();
    expect(find.text('Turn off Wi-Fi?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(writes, 0);

    await tester.tap(find.byType(CupertinoSwitch));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Turn Off'));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(find.text('Router rejected the command.'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch)).value,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('devices search by address and expose device details', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keeneticCredentialsStoreProvider.overrideWithValue(_Credentials()),
          keeneticDevicesProvider.overrideWith(
            (ref) async => const [
              KeeneticDevice(
                mac: 'AA:BB:CC:DD:EE:01',
                name: 'Phone',
                ip: '192.168.1.40',
                active: true,
                registered: true,
              ),
              KeeneticDevice(
                mac: 'AA:BB:CC:DD:EE:02',
                name: 'Printer',
                ip: '192.168.1.50',
              ),
            ],
          ),
        ],
        child: app(const KeeneticDevicesScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Printer'), findsOneWidget);
    await tester.enterText(
      find.byType(CupertinoSearchTextField),
      '192.168.1.40',
    );
    await tester.pumpAndSettle();
    expect(find.text('Phone'), findsOneWidget);
    expect(find.text('Printer'), findsNothing);
    await tester.tap(find.text('Phone'));
    await tester.pumpAndSettle();
    expect(find.text('AA:BB:CC:DD:EE:01'), findsOneWidget);
    expect(find.text('Registered device'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('router overview fits a phone and renders reported metrics', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keeneticCredentialsStoreProvider.overrideWithValue(_Credentials()),
          keeneticRouterStatusProvider.overrideWith(
            (ref) async => const KeeneticRouterStatus(
              model: 'Keenetic Giga',
              firmware: '4.2.4',
              cpuPercent: 8,
              memoryUsedKiB: 65536,
              memoryTotalKiB: 262144,
              uptimeSeconds: 90061,
            ),
          ),
          keeneticDevicesProvider.overrideWith((ref) async => const []),
          keeneticAccessPointsProvider.overrideWith((ref) async => const []),
        ],
        child: app(const KeeneticHomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Keenetic Giga'), findsOneWidget);
    expect(find.text('8%'), findsOneWidget);
    expect(find.text('25%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
