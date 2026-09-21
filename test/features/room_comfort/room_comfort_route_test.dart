import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/room_comfort/presentation/room_comfort_route.dart';
import 'package:larenor/features/room_comfort/presentation/room_comfort_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/features/settings/presentation/settings_split_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import '../server/server_admin_test_support.dart';

Map<String, Object?> _plan() => {
  'schemaVersion': 1,
  'planId': 'd' * 32,
  'coreId': 'a' * 32,
  'homeId': 'b' * 32,
  'homeRevision': 1,
  'policyId': 'e' * 32,
  'policyRevision': 2,
  'policyHash': 'f' * 64,
  'actorAccountId': adminId,
  'accountRevision': 1,
  'sessionFamilyId': '1' * 32,
  'generatedAtMs': 1788609600000,
  'inputRevisions': {'bounded': true},
  'occupancyAdvisory': {'2' * 32: 'occupied'},
  'items': [
    {
      'schemaVersion': 1,
      'room': {
        'schemaVersion': 1,
        'coreId': 'a' * 32,
        'homeId': 'b' * 32,
        'roomId': '2' * 32,
        'roomRevision': 4,
        'areaId': '3' * 32,
        'areaRevision': 5,
        'hvac': <String, Object?>{},
        'window': <String, Object?>{},
      },
      'status': 'planned',
      'reason': 'temperature_low',
      'hvacMode': 'heat',
      'windowState': 'closed',
    },
  ],
};

void main() {
  late AdminFixture fixture;

  Future<void> mount(
    WidgetTester tester,
    Widget home, {
    String language = 'en',
    double width = 600,
    bool settle = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1000);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
        ],
        child: CupertinoApp(
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
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
      if (request.method == 'GET' &&
          request.url.path.contains('/room-comfort/') &&
          request.url.path.endsWith('/plan')) {
        return fixture.json({'schemaVersion': 1, 'plan': _plan()});
      }
      return fixture.defaultResponse(request);
    };
    await fixture.account.initialize();
  });

  tearDown(() => fixture.account.dispose());

  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1280.0]) {
      testWidgets('Settings discovers room comfort $language $width at 2x', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        try {
          await mount(
            tester,
            SettingsSplitScreen(comfortGateCurrent: () => true),
            language: language,
            width: width,
          );
          final entry = find
              .text(language == 'tr' ? 'Oda konforu' : 'Room comfort')
              .first;
          await tester.ensureVisible(entry);
          final button = find.ancestor(
            of: entry,
            matching: find.byType(CupertinoButton),
          );
          expect(tester.getSemantics(button).flagsCollection.isButton, isTrue);
          expect(tester.getRect(button).height, greaterThanOrEqualTo(48));
          Focus.of(tester.element(entry)).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(find.byType(RoomComfortRoute), findsOneWidget);
          expect(find.byType(RoomComfortScreen), findsOneWidget);
          final calls = fixture.calls.where(
            (call) => call.url.path.contains('/room-comfort/'),
          );
          expect(calls, hasLength(1));
          expect(
            calls.single.headers['authorization'],
            'Bearer synthetic_admin_access_12345',
          );
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }
  }

  testWidgets('gate and account changes retire comfort callbacks', (
    tester,
  ) async {
    await mount(tester, RoomComfortRoute(gateCurrent: () => false));
    expect(find.byType(RoomComfortScreen), findsNothing);
    expect(
      fixture.calls.where((call) => call.url.path.contains('/room-comfort/')),
      isEmpty,
    );

    final delayed = Completer<http.Response>();
    fixture.respond = (request) async {
      if (request.url.path.contains('/room-comfort/')) return delayed.future;
      return fixture.defaultResponse(request);
    };
    await tester.pumpWidget(const SizedBox.shrink());
    await mount(
      tester,
      RoomComfortRoute(gateCurrent: () => true),
      settle: false,
    );
    await tester.pump();
    unawaited(fixture.account.signOut());
    delayed.complete(fixture.json({'schemaVersion': 1, 'plan': _plan()}));
    await tester.pumpAndSettle();
    expect(find.byType(RoomComfortScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
