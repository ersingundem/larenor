import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/epaper/presentation/epaper_management_route.dart';
import 'package:larenor/features/epaper/presentation/epaper_management_screen.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import '../server/server_admin_test_support.dart';

const _device = 'hall-display';

final class _Source implements HomeSourcePersistence {
  @override
  Future<HomeSource> read() async => HomeSource.verifiedCore;

  @override
  Future<void> write(HomeSource source) async {}
}

final class _Wire {
  int confirmCalls = 0, readbackCalls = 0;

  Map<String, Object?> get authority => {
    'schemaVersion': 1,
    'coreId': 'a' * 32,
    'homeId': 'b' * 32,
    'accountId': adminId,
    'sessionFamilyId': sessionFamilyId,
    'homeRevision': 4,
    'accountRevision': 8,
    'sessionRevision': 1,
    'canManage': true,
  };

  Map<String, Object?> device({String trust = 'acknowledged'}) => {
    'schemaVersion': 1,
    'authority': authority,
    'deviceId': _device,
    'name': 'Hall display',
    'deviceRevision': '7',
    'mappingRevision': 1,
    'bridgeRevision': '2',
    'layoutRevision': '4',
    'dataRevision': '9',
    'policyRevision': '5',
    'stored': true,
    'reachable': true,
    'connectivity': 'online',
    'capabilityVerified': true,
    'batteryPercent': 70,
    'lastSeenAtMs': DateTime.now().millisecondsSinceEpoch,
    'width': 800,
    'height': 480,
    'supportedColors': ['black', 'white', 'red'],
    'retainsLastImageOffline': true,
    'snapshotTrust': trust,
    'snapshotDigest': '1' * 64,
    'verifiedDigest': null,
    'expiresAtMs': DateTime.now()
        .add(const Duration(minutes: 5))
        .millisecondsSinceEpoch,
  };

  http.Response _json(Object value) => http.Response(
    jsonEncode(value),
    200,
    headers: {'content-type': 'application/json'},
  );

  Future<http.Response> call(http.Request request) async {
    final path = request.url.path;
    if (path.endsWith('/authority')) return _json(authority);
    if (path.endsWith('/devices') && !path.contains('/admin/')) {
      return _json({
        'schemaVersion': 1,
        'devices': [device()],
      });
    }
    if (path.endsWith('/previews')) {
      return _json({
        'schemaVersion': 1,
        'authority': authority,
        'requestId': 'f' * 32,
        'deviceId': _device,
        'deviceRevision': '7',
        'action': 'refresh',
        'expectedLayoutRevision': '4',
        'expiresAtMs': DateTime.now()
            .add(const Duration(minutes: 5))
            .millisecondsSinceEpoch,
      });
    }
    if (path.endsWith('/confirm')) {
      confirmCalls++;
      return _json({
        'schemaVersion': 1,
        'authority': authority,
        'requestId': 'f' * 32,
        'deviceId': _device,
        'deviceRevision': '7',
        'action': 'refresh',
        'status': 'uncertain',
        'observedLayoutRevision': null,
        'observedSnapshotDigest': null,
      });
    }
    if (path.endsWith('/$_device')) {
      readbackCalls++;
      return _json(device(trust: 'pending'));
    }
    throw StateError('unexpected epaper request');
  }
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var attempt = 0; attempt < 100 && !done(); attempt++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(done(), isTrue);
}

void main() {
  testWidgets('route-owned confirmation keeps exact runtime alive', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fixture = AdminFixture();
    await fixture.account.initialize();
    final home = HomeSessionController(
      store: _Source(),
      account: fixture.account,
    );
    await home.initialize();
    home.runtimeMounted(home.runtimeIdentity);
    addTearDown(() {
      home.dispose();
      fixture.account.dispose();
    });
    final wire = _Wire();
    final client = MockClient(wire.call);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeSessionControllerProvider.overrideWithValue(home),
          windowPolicySnapshotProvider.overrideWith((_) async* {
            yield const WindowPolicySnapshot(
              supported: false,
              isResumed: true,
              hasWindowFocus: true,
              reason: WindowRestrictionReason.unsupported,
            );
          }),
        ],
        child: AppInteractionScope(
          controller: home.interaction,
          child: CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: EpaperManagementRoute(
              apiFactory: (endpoint) =>
                  LarenorServerApi(endpoint: endpoint, client: client),
            ),
          ),
        ),
      ),
    );
    await _pumpUntil(
      tester,
      () =>
          find
              .byKey(const ValueKey('epaper-refresh-$_device'))
              .evaluate()
              .length ==
          1,
    );
    expect(find.byType(EpaperManagementScreen), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('epaper-refresh-$_device')));
    await _pumpUntil(
      tester,
      () => find.byType(CupertinoAlertDialog).evaluate().length == 1,
    );
    expect(find.byType(CupertinoAlertDialog), findsOneWidget);
    final coveredController = tester
        .widget<EpaperManagementScreen>(find.byType(EpaperManagementScreen))
        .controller;
    final capturedConfirm = tester
        .widget<CupertinoDialogAction>(
          find.descendant(
            of: find.byKey(const ValueKey('epaper-confirm-action')),
            matching: find.byType(CupertinoDialogAction),
          ),
        )
        .onPressed!;
    final capturedCancel = tester
        .widget<CupertinoDialogAction>(
          find.descendant(
            of: find.byKey(const ValueKey('epaper-cancel-action')),
            matching: find.byType(CupertinoDialogAction),
          ),
        )
        .onPressed!;
    final navigator = Navigator.of(
      tester.element(find.byType(EpaperManagementScreen)),
    );
    final foreignRoute = navigator.push<void>(
      CupertinoPageRoute(
        builder: (_) => const CupertinoPageScaffold(
          child: Center(child: Text('Covered foreign route')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Covered foreign route'), findsOneWidget);

    capturedConfirm();
    capturedCancel();
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('Covered foreign route'), findsOneWidget);
    expect(wire.confirmCalls, 0);
    expect(coveredController.pendingPreview, isNull);

    navigator.pop();
    await tester.pumpAndSettle();
    await foreignRoute;
    await _pumpUntil(
      tester,
      () =>
          find
              .byKey(const ValueKey('epaper-refresh-$_device'))
              .evaluate()
              .length ==
          1,
    );

    await tester.tap(find.byKey(const ValueKey('epaper-refresh-$_device')));
    await _pumpUntil(
      tester,
      () => find.byType(CupertinoAlertDialog).evaluate().length == 1,
    );
    await tester.tap(find.byKey(const ValueKey('epaper-confirm-action')));
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(wire.confirmCalls, 1);
    expect(wire.readbackCalls, 2);
    expect(find.byType(EpaperManagementScreen), findsOneWidget);
    expect(tester.takeException(), isNull);

    await home.choose(HomeSource.directLocal);
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.byType(EpaperManagementScreen), findsNothing);
  });

  testWidgets('parent removal safely retires its owned confirmation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fixture = AdminFixture();
    await fixture.account.initialize();
    final home = HomeSessionController(
      store: _Source(),
      account: fixture.account,
    );
    await home.initialize();
    home.runtimeMounted(home.runtimeIdentity);
    addTearDown(() {
      home.dispose();
      fixture.account.dispose();
    });
    final wire = _Wire();
    final client = MockClient(wire.call);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeSessionControllerProvider.overrideWithValue(home),
          windowPolicySnapshotProvider.overrideWith((_) async* {
            yield const WindowPolicySnapshot(
              supported: false,
              isResumed: true,
              hasWindowFocus: true,
              reason: WindowRestrictionReason.unsupported,
            );
          }),
        ],
        child: AppInteractionScope(
          controller: home.interaction,
          child: CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: EpaperManagementRoute(
              apiFactory: (endpoint) =>
                  LarenorServerApi(endpoint: endpoint, client: client),
            ),
          ),
        ),
      ),
    );
    await _pumpUntil(
      tester,
      () =>
          find
              .byKey(const ValueKey('epaper-refresh-$_device'))
              .evaluate()
              .length ==
          1,
    );
    final screen = tester.widget<EpaperManagementScreen>(
      find.byType(EpaperManagementScreen),
    );
    final parentRoute = ModalRoute.of(
      tester.element(find.byType(EpaperManagementScreen)),
    )!;

    await tester.tap(find.byKey(const ValueKey('epaper-refresh-$_device')));
    await _pumpUntil(
      tester,
      () => find.byType(CupertinoAlertDialog).evaluate().length == 1,
    );

    parentRoute.navigator!.removeRoute(parentRoute);
    await tester.pumpAndSettle();

    expect(find.byType(CupertinoAlertDialog), findsNothing);
    expect(screen.controller.pendingPreview, isNull);
    expect(wire.confirmCalls, 0);
    expect(tester.takeException(), isNull);
  });
}
