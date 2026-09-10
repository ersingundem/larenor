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
          'firmwareRevision': 44,
          'statusRevision': 71,
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
          {
            'id': 'guest0',
            'name': 'Guest Wi-Fi',
            'kind': 'wifi',
            'online': true,
            'address': '192.0.2.3',
            'rxBytes': 400,
            'txBytes': 200,
            'guest': true,
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
            'interfaceId': 'wan0',
            'online': true,
            'registered': true,
            'internetAccess': 'allowed',
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
  VoidCallback? onRefresh,
  VoidCallback? onCommands,
  double width = 600,
}) async {
  tester.view.physicalSize = Size(width, 900);
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
          width: width,
          height: 460,
          child: CoreKeeneticDashboardCard(
            title: 'Main router',
            snapshot: value,
            failure: failure,
            stale: stale,
            loading: value == null && failure == null && !stale,
            onPressed: onPressed,
            onRefresh: onRefresh,
            onCommands: onCommands,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('command entry requires admin PIN and the exact live snapshot', () {
    final session = ServerSession(
      endpoint: ServerEndpoint('https://core.invalid'),
      accessToken: 'access-token-for-test-1234',
      refreshToken: 'refresh-token-for-test-1234',
      expiresAt: DateTime.utc(2026, 9, 11, 14),
      user: const ServerUser(
        id: 'admin',
        username: 'admin',
        role: ServerRole.admin,
        mustChangePassword: false,
      ),
      context: contextId,
    );
    expect(
      coreKeeneticCommandEntryAllowed(
        session: session,
        target: target(),
        snapshot: snapshot(),
        pinConfigured: true,
      ),
      isTrue,
    );
    expect(
      coreKeeneticCommandEntryAllowed(
        session: session,
        target: target(),
        snapshot: snapshot(),
        pinConfigured: false,
      ),
      isFalse,
    );
    expect(
      coreKeeneticCommandEntryAllowed(
        session: session.withUser(
          const ServerUser(
            id: 'member',
            username: 'member',
            role: ServerRole.member,
            mustChangePassword: false,
          ),
        ),
        target: target(),
        snapshot: snapshot(),
        pinConfigured: true,
      ),
      isFalse,
    );
    expect(
      coreKeeneticCommandEntryAllowed(
        session: session,
        target: HomeResourceRecord.fromJson({
          'ref': {
            'schemaVersion': 1,
            'coreId': contextId.coreId,
            'homeId': contextId.homeId,
            'kind': 'resource',
            'id': target().id,
          },
          'label': 'Main router',
          'order': 0,
          'revision': 8,
          'aclRevision': 9,
          'permissions': {'read': true, 'write': true},
        }, expectedContext: contextId),
        snapshot: snapshot(),
        pinConfigured: true,
      ),
      isFalse,
    );
  });

  for (final width in [600.0, 1280.0]) {
    testWidgets('$width tablet card exposes complete summary at 2x text', (
      tester,
    ) async {
      var opened = 0, refreshed = 0, commands = 0;
      await mount(
        tester,
        width: width,
        value: snapshot(),
        onPressed: () => opened++,
        onRefresh: () => refreshed++,
        onCommands: () => commands++,
      );
      expect(find.textContaining('198.51.100.20'), findsOneWidget);
      expect(find.textContaining('9.0'), findsOneWidget);
      expect(find.textContaining('3.0'), findsOneWidget);
      expect(find.textContaining('700.0 MB'), findsOneWidget);
      expect(find.textContaining('200.0 MB'), findsOneWidget);
      expect(find.textContaining('4.3.6'), findsOneWidget);
      expect(find.textContaining('Guest Wi-Fi'), findsWidgets);
      expect(find.textContaining('CPU'), findsOneWidget);
      expect(find.textContaining('Memory'), findsOneWidget);
      expect(find.textContaining('1'), findsWidgets);
      final semantics = tester.getSemantics(
        find.byKey(const ValueKey('core-keenetic-dashboard-card')),
      );
      expect(semantics.label, contains('Main router'));
      for (final button in tester.widgetList<CupertinoButton>(
        find.byType(CupertinoButton),
      )) {
        expect(button.minimumSize?.height ?? 0, greaterThanOrEqualTo(48));
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(opened + refreshed + commands, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('refresh is explicit and command entry is capability gated', (
    tester,
  ) async {
    var refreshed = 0;
    await mount(
      tester,
      value: snapshot(),
      onPressed: () {},
      onRefresh: () => refreshed++,
    );
    expect(find.byKey(const ValueKey('core-keenetic-commands')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('core-keenetic-refresh-card')));
    await tester.pump();
    expect(refreshed, 1);
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
