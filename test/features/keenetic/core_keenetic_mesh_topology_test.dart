import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/keenetic/core/domain/core_keenetic_models.dart';
import 'package:larenor/features/keenetic/core/presentation/core_keenetic_screen.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'core_keenetic_api_test.dart' show refJson, target;

Map<String, dynamic> topologyJson() => {
  'ref': refJson(),
  'bindingId': '4' * 32,
  'bindingRevision': 1,
  'serviceId': '5' * 32,
  'serviceRevision': 1,
  'resourceRevision': 1,
  'aclRevision': 1,
  'observedAt': '2026-09-10T12:00:00Z',
  'remainingTtlMs': 5000,
  'nodes': [
    {
      'id': '0123456789abcdef',
      'name': 'Ana Keenetic',
      'model': 'Titan (KN-1810)',
      'role': 'controller',
      'online': true,
      'parentId': null,
      'backhaulType': null,
      'backhaulQuality': null,
      'pathCost': null,
    },
    {
      'id': '1111111111111111',
      'name': 'Salon Genişletici',
      'model': 'Buddy 6 (KN-3411)',
      'role': 'extender',
      'online': true,
      'parentId': '0123456789abcdef',
      'backhaulType': 'wifi_5',
      'backhaulQuality': 'good',
      'pathCost': 50,
    },
  ],
  'networks': [
    {
      'id': 'WifiMaster1/AccessPoint0',
      'ssid': 'Larenor Home',
      'band': '5',
      'channel': 44,
      'clientCount': 7,
      'online': true,
    },
  ],
};

void main() {
  test('topology parser rejects raw MAC and broken parent graph', () {
    final snapshot = CoreKeeneticTopologySnapshot.fromJson(
      topologyJson(),
      target: target(),
    );
    expect(snapshot.nodes, hasLength(2));
    expect(snapshot.networks.single.clientCount, 7);
    for (final invalid in [
      {...topologyJson(), 'password': 'secret'},
      {
        ...topologyJson(),
        'nodes': [
          {
            ...(topologyJson()['nodes'] as List).last as Map,
            'macAddress': '50:FF:20:00:00:3A',
          },
        ],
      },
      {
        ...topologyJson(),
        'nodes': [
          ...(topologyJson()['nodes'] as List),
          {
            ...(topologyJson()['nodes'] as List).last as Map,
            'id': '2222222222222222',
            'parentId': 'ffffffffffffffff',
          },
        ],
      },
    ]) {
      expect(
        () => CoreKeeneticTopologySnapshot.fromJson(invalid, target: target()),
        throwsA(isA<LarenorServerException>()),
      );
    }
  });

  for (final width in [600.0, 1280.0]) {
    testWidgets('$width topology is keyboard and 2x-text accessible', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        CupertinoApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
            ),
            child: child!,
          ),
          home: CupertinoPageScaffold(
            child: SafeArea(
              child: CoreKeeneticTopologyPanel(
                topology: CoreKeeneticTopologySnapshot.fromJson(
                  topologyJson(),
                  target: target(),
                ),
                enabled: true,
                isCurrent: () => true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Salon Genişletici'), findsOneWidget);
      expect(find.text('Larenor Home'), findsOneWidget);
      await tester.tap(find.text('Salon Genişletici'));
      await tester.pump();
      expect(find.textContaining('Wi-Fi 5'), findsOneWidget);
      expect(find.textContaining('50'), findsOneWidget);
      expect(find.textContaining('50:FF'), findsNothing);
      expect(
        find.bySemanticsLabel(RegExp('Salon Genişletici.*online')),
        findsWidgets,
      );
      final buttons = tester.widgetList<CupertinoButton>(
        find.byType(CupertinoButton),
      );
      expect(buttons, isNotEmpty);
      expect(
        buttons.every((button) => (button.minimumSize?.height ?? 0) >= 48),
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }

  testWidgets('offline topology is explicit and retired selection is blocked', (
    tester,
  ) async {
    final raw = topologyJson();
    final nodes = (raw['nodes'] as List).map((item) => Map.of(item as Map)).toList();
    nodes[1]['online'] = false;
    raw['nodes'] = nodes;
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CoreKeeneticTopologyPanel(
          topology: CoreKeeneticTopologySnapshot.fromJson(raw, target: target()),
          enabled: false,
          isCurrent: () => false,
        ),
      ),
    );
    expect(find.text('Offline'), findsWidgets);
    await tester.tap(find.text('Salon Genişletici'), warnIfMissed: false);
    await tester.pump();
    expect(find.textContaining('Wi-Fi 5'), findsNothing);
  });
}
