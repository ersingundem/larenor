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
import 'package:larenor/features/room_presence/presentation/room_presence_management_screen.dart';
import 'package:larenor/features/room_presence/presentation/room_presence_route.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import '../server/server_admin_test_support.dart';

const _device = '66666666666666666666666666666666';
const _room = '99999999999999999999999999999999';

final class _Source implements HomeSourcePersistence {
  @override
  Future<HomeSource> read() async => HomeSource.verifiedCore;

  @override
  Future<void> write(HomeSource source) async {}
}

final class _Wire {
  Map<String, dynamic>? authority;
  int scopeCalls = 0, confirmCalls = 0, readbackCalls = 0;

  http.Response _json(Object value) => http.Response(
    jsonEncode(value),
    200,
    headers: {'content-type': 'application/json'},
  );

  Map<String, dynamic> _evidence({int calibration = 1}) => {
    'schemaVersion': 1,
    'authority': authority,
    'deviceId': _device,
    'deviceName': 'Owner tablet',
    'deviceRevision': 9,
    'modelRevision': 4,
    'policyRevision': 7,
    'consentRevision': 11,
    'consentActive': true,
    'configuredRoomId': _room,
    'configuredRoomName': 'Living room',
    'configuredRoomRevision': 13,
    'detectedRoomId': _room,
    'detectedRoomRevision': 13,
    'estimateRevision': 'b' * 32,
    'transitionRevision': 1,
    'calibrationRevision': calibration,
    'state': 'present',
    'confidencePermille': 880,
    'sampleCount': 2,
    'observedAtMs': DateTime.now().millisecondsSinceEpoch,
    'stored': true,
    'providerReachable': true,
    'advisoryOnly': true,
    'grantsAccess': false,
  };

  Map<String, dynamic> _preview() => {
    'schemaVersion': 1,
    'authority': authority,
    'requestId': 'c' * 32,
    'deviceId': _device,
    'deviceRevision': 9,
    'modelRevision': 4,
    'roomId': _room,
    'roomRevision': 13,
    'policyRevision': 7,
    'consentRevision': 11,
    'previousCalibrationRevision': 1,
    'nextCalibrationRevision': 2,
    'expiresAtMs': DateTime.now()
        .add(const Duration(minutes: 5))
        .millisecondsSinceEpoch,
  };

  Future<http.Response> call(http.Request request) async {
    final path = request.url.path;
    final body = request.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(request.body) as Map<String, dynamic>;
    if (path.endsWith('/scope')) {
      scopeCalls++;
      authority = {
        'schemaVersion': 1,
        'coreId': 'a' * 32,
        'homeId': 'b' * 32,
        'accountId': adminId,
        'sessionFamilyId': sessionFamilyId,
        'routeId': body['routeId'],
        'homeRevision': 5,
        'accountRevision': 8,
        'clientSessionRevision': body['clientSessionRevision'],
        'routeRevision': body['routeRevision'],
        'bindingTag': 'd' * 64,
      };
      return _json(authority!);
    }
    if (path.endsWith('/devices/query')) {
      return _json({
        'schemaVersion': 1,
        'authority': authority,
        'devices': [_evidence()],
      });
    }
    if (path.endsWith('/calibration/preview')) return _json(_preview());
    if (path.endsWith('/confirm')) {
      confirmCalls++;
      return _json(
        {..._preview(), 'observedCalibrationRevision': 2, 'status': 'applied'}
          ..remove('nextCalibrationRevision')
          ..remove('expiresAtMs'),
      );
    }
    if (path.endsWith('/readback')) {
      readbackCalls++;
      return _json(_evidence(calibration: 2));
    }
    throw StateError('unexpected room-presence request');
  }
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
            home: RoomPresenceRoute(
              apiFactory: (endpoint) =>
                  LarenorServerApi(endpoint: endpoint, client: client),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RoomPresenceManagementScreen), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('presence-calibrate-$_device')));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoAlertDialog), findsOneWidget);
    final coveredController = tester
        .widget<RoomPresenceManagementScreen>(
          find.byType(RoomPresenceManagementScreen),
        )
        .controller;
    final capturedConfirm = tester
        .widget<CupertinoDialogAction>(
          find.descendant(
            of: find.byKey(const ValueKey('presence-confirm-calibration')),
            matching: find.byType(CupertinoDialogAction),
          ),
        )
        .onPressed!;
    final capturedCancel = tester
        .widget<CupertinoDialogAction>(
          find.descendant(
            of: find.byKey(const ValueKey('presence-cancel-calibration')),
            matching: find.byType(CupertinoDialogAction),
          ),
        )
        .onPressed!;
    final navigator = Navigator.of(
      tester.element(find.byType(RoomPresenceManagementScreen)),
    );
    final coveredForeignRoute = navigator.push<void>(
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
    await tester.pumpAndSettle();
    expect(find.text('Covered foreign route'), findsOneWidget);
    expect(wire.confirmCalls, 0);
    expect(coveredController.pendingPreview, isNull);

    navigator.pop();
    await tester.pumpAndSettle();
    await coveredForeignRoute;
    expect(find.byType(RoomPresenceManagementScreen), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('presence-calibrate-$_device')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('presence-confirm-calibration')),
    );
    await tester.pumpAndSettle();

    expect(wire.confirmCalls, 1);
    expect(wire.readbackCalls, 1);
    expect(find.byType(RoomPresenceManagementScreen), findsOneWidget);
    expect(tester.takeException(), isNull);

    final scopesBeforeForeignRoute = wire.scopeCalls;
    final foreignRoute = navigator.push<void>(
      CupertinoPageRoute(
        builder: (_) => const CupertinoPageScaffold(
          child: Center(child: Text('Foreign route')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RoomPresenceManagementScreen), findsNothing);
    navigator.pop();
    await tester.pumpAndSettle();
    await foreignRoute;
    expect(find.byType(RoomPresenceManagementScreen), findsOneWidget);
    expect(wire.scopeCalls, greaterThan(scopesBeforeForeignRoute));

    await fixture.account.signOut();
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.byType(RoomPresenceManagementScreen), findsNothing);
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
            home: RoomPresenceRoute(
              apiFactory: (endpoint) =>
                  LarenorServerApi(endpoint: endpoint, client: client),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final screen = tester.widget<RoomPresenceManagementScreen>(
      find.byType(RoomPresenceManagementScreen),
    );
    final parentRoute = ModalRoute.of(
      tester.element(find.byType(RoomPresenceManagementScreen)),
    )!;

    await tester.tap(find.byKey(const ValueKey('presence-calibrate-$_device')));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoAlertDialog), findsOneWidget);

    parentRoute.navigator!.removeRoute(parentRoute);
    await tester.pumpAndSettle();

    expect(find.byType(CupertinoAlertDialog), findsNothing);
    expect(screen.controller.pendingPreview, isNull);
    expect(wire.confirmCalls, 0);
    expect(tester.takeException(), isNull);
  });
}
