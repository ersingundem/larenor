import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/ev_charging/presentation/ev_charging_route.dart';
import 'package:larenor/features/ev_charging/presentation/ev_charging_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import '../server/server_admin_test_support.dart';

Map<String, Object?> capability() => {
  'schemaVersion': 1,
  'coreId': 'a' * 32,
  'homeId': 'b' * 32,
  'state': 'ready',
  'providerKind': 'ocpp',
  'canPlan': true,
  'canControl': true,
  'reason': 'ready',
  'chargers': [
    {
      'schemaVersion': 1,
      'chargerId': '3' * 32,
      'label': 'Garage charger',
      'chargerRevision': 4,
      'scheduleRevision': 7,
      'tariffRevision': 5,
      'powerBudgetRevision': 7,
      'currentSoc': 40,
      'batteryCapacityWh': 40000,
      'maxCurrentAmp': 16,
    },
  ],
};

void main() {
  late AdminFixture fixture;
  Future<void> mount(
    WidgetTester tester,
    Widget home, {
    bool settle = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 1000);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
        ],
        child: CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: home,
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  setUp(() async {
    fixture = AdminFixture();
    fixture.respond = (request) async {
      if (request.url.path.endsWith(
        '/ev-charging/${'a' * 32}/${'b' * 32}/capability',
      )) {
        return fixture.json(capability());
      }
      return fixture.defaultResponse(request);
    };
    await fixture.account.initialize();
  });
  tearDown(() => fixture.account.dispose());

  testWidgets('route uses authenticated Core capability and gate authority', (
    tester,
  ) async {
    await mount(tester, EvChargingRoute(gateCurrent: () => true));
    expect(find.byType(EvChargingScreen), findsOneWidget);
    final call = fixture.calls.singleWhere(
      (item) => item.url.path.contains('/ev-charging/'),
    );
    expect(
      call.headers['authorization'],
      'Bearer synthetic_admin_access_12345',
    );
    expect(find.text('Garage charger'), findsOneWidget);
  });

  testWidgets('account retirement discards delayed capability', (tester) async {
    final delayed = Completer<http.Response>();
    fixture.respond = (request) => request.url.path.contains('/ev-charging/')
        ? delayed.future
        : Future.value(fixture.defaultResponse(request));
    await mount(
      tester,
      EvChargingRoute(gateCurrent: () => true),
      settle: false,
    );
    await tester.pump();
    unawaited(fixture.account.signOut());
    delayed.complete(fixture.json(capability()));
    await tester.pumpAndSettle();
    expect(find.byType(EvChargingScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
