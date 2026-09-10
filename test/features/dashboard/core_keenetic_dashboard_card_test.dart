import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/presentation/tiles/core_keenetic_tile.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/keenetic/core/domain/core_keenetic_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

final contextId = ServerContext.fromJson(const {
  'schemaVersion': 1,
  'coreId': '11111111111111111111111111111111',
  'homeId': '22222222222222222222222222222222',
});

HomeResourceRecord target() => HomeResourceRecord.fromJson({
  'ref': {
    'schemaVersion': 1,
    'coreId': contextId.coreId,
    'homeId': contextId.homeId,
    'kind': 'resource',
    'id': '33333333333333333333333333333333',
  },
  'label': 'Main router',
  'order': 0,
  'revision': 7,
  'aclRevision': 9,
  'permissions': {'read': true, 'write': false},
}, expectedContext: contextId);

CoreKeeneticSnapshot snapshot({bool online = true}) =>
    CoreKeeneticSnapshot.fromJson({
      'ref': {
        'schemaVersion': 1,
        'coreId': contextId.coreId,
        'homeId': contextId.homeId,
        'kind': 'resource',
        'id': target().id,
      },
      'bindingId': '44444444444444444444444444444444',
      'bindingRevision': 4,
      'serviceId': '55555555555555555555555555555555',
      'serviceRevision': 3,
      'resourceRevision': 7,
      'aclRevision': 9,
      'observedAt': '2026-09-10T09:00:00Z',
      'remainingTtlMs': 5000,
      'telemetry': {
        'status': {
          'online': online,
          'publicIp': '198.51.100.20',
          'uptimeSeconds': 86400,
          'firmware': '4.3.6',
          'cpuPercent': 17.5,
          'memoryPercent': 42.0,
        },
        'interfaces': [
          {
            'id': 'wan0',
            'name': 'Internet',
            'kind': 'wan',
            'online': online,
            'address': '192.0.2.2',
            'rxBytes': 1200,
            'txBytes': 500,
          },
        ],
        'traffic': {
          'rxBytes': 1200,
          'txBytes': 500,
          'downloadBps': 9000000,
          'uploadBps': 3000000,
        },
        'hosts': [
          {
            'id': 'host-1',
            'name': 'Tablet',
            'ipAddress': '192.0.2.20',
            'macAddress': '02:00:00:00:00:01',
            'interfaceId': 'wan0',
            'online': true,
            'registered': true,
          },
        ],
      },
    }, target: target());

Future<void> mount(
  WidgetTester tester, {
  CoreKeeneticSnapshot? value,
  String? failure,
  bool stale = false,
  VoidCallback? onPressed,
}) async {
  tester.view.physicalSize = const Size(1180, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    CupertinoApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: CupertinoPageScaffold(
        child: SizedBox(
          width: 520,
          height: 300,
          child: CoreKeeneticDashboardCard(
            title: 'Main router',
            snapshot: value,
            failure: failure,
            stale: stale,
            loading: value == null && failure == null && !stale,
            onPressed: onPressed,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('tablet card exposes typed summary, TalkBack and keyboard', (
    tester,
  ) async {
    var opened = 0;
    await mount(tester, value: snapshot(), onPressed: () => opened++);
    expect(find.textContaining('198.51.100.20'), findsOneWidget);
    expect(find.textContaining('CPU'), findsOneWidget);
    expect(find.textContaining('RAM'), findsOneWidget);
    expect(find.textContaining('9.0'), findsOneWidget);
    expect(find.textContaining('3.0'), findsOneWidget);
    expect(find.textContaining('1'), findsWidgets);
    final semantics = tester.getSemantics(
      find.byKey(const ValueKey('core-keenetic-dashboard-card')),
    );
    expect(semantics.label, contains('Main router'));
    final button = tester.widget<CupertinoButton>(find.byType(CupertinoButton));
    expect(button.minimumSize, const Size.square(48));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(opened, 1);
    expect(tester.takeException(), isNull);
  });

  for (final (name, failure, stale, expected) in [
    ('unknown', null, false, 'Loading'),
    ('denied', 'forbidden', false, 'cannot read'),
    ('upstream denied', 'keenetic_upstream_denied', false, 'denied'),
    ('unsupported', 'keenetic_snapshot_unsupported', false, 'not supported'),
    ('stale', null, true, 'stale'),
  ]) {
    testWidgets('$name is explicit and secret free', (tester) async {
      await mount(tester, failure: failure, stale: stale);
      expect(find.textContaining(expected), findsOneWidget);
      expect(find.textContaining('token'), findsNothing);
    });
  }

  testWidgets('offline is distinct from stale and unknown', (tester) async {
    await mount(tester, value: snapshot(online: false));
    expect(find.textContaining('Offline'), findsOneWidget);
    expect(find.textContaining('stale'), findsNothing);
  });
}
