import 'dart:async';
import 'dart:convert';

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

Map<String, Object?> _setupService() => {
  'id': '4' * 32,
  'name': 'Verified Home Assistant',
  'kind': 'home_assistant',
  'baseUrl': 'https://ha.fixture.invalid',
  'revision': 3,
  'credentialKeys': ['token'],
  'verification': {
    'state': 'authenticated',
    'checkedAt': '2026-09-05T08:00:00Z',
    'version': '2026.9',
  },
};

Map<String, Object?> _setupResource(String id, String kind, String label) => {
  'ref': {
    'schemaVersion': 1,
    'coreId': 'a' * 32,
    'homeId': 'b' * 32,
    'kind': kind,
    'id': id,
  },
  'label': label,
  'order': 0,
  'revision': 1,
  'aclRevision': 1,
  'permissions': {'read': true, 'write': true},
};

Map<String, Object?> _sourceConfiguration([int revision = 4]) => {
  'schemaVersion': 1,
  'revision': revision,
  'serviceId': '4' * 32,
  'serviceRevision': 3,
  'weatherEntityId': 'weather.home',
  'aqiEntityId': 'sensor.outdoor_aqi',
  'targetTemperatureMilliC': 22000,
  'temperatureToleranceMilliC': 1000,
  'humidityHighPermille': 700,
  'co2HighPpm': 1000,
  'vocHighPpb': 500,
  'outdoorAqiLimit': 100,
  'freezeThresholdMilliC': 3000,
  'indoorMaxAgeMs': 60000,
  'outdoorMaxAgeMs': 120000,
  'occupancyMaxAgeMs': 60000,
  'previewTtlMs': 30000,
  'rooms': [
    {
      'roomId': '2' * 32,
      'roomRevision': 1,
      'areaId': '3' * 32,
      'areaRevision': 1,
      'climateEntityId': 'climate.living_room',
      'windowEntityId': 'cover.living_room_window',
      'temperatureEntityId': 'sensor.living_temperature',
      'humidityEntityId': 'sensor.living_humidity',
      'co2EntityId': 'sensor.living_co2',
      'vocEntityId': 'sensor.living_voc',
      'smokeEntityId': 'binary_sensor.living_smoke',
      'occupancyEntityId': 'binary_sensor.living_occupancy',
    },
  ],
};

Map<String, Object?> _entityCatalog() => {
  'schemaVersion': 1,
  'entities': {
    'climate': ['climate.living_room'],
    'cover': ['cover.living_room_window'],
    'sensor': [
      'sensor.living_co2',
      'sensor.living_humidity',
      'sensor.living_temperature',
      'sensor.living_voc',
      'sensor.outdoor_aqi',
    ],
    'binary_sensor': [
      'binary_sensor.living_occupancy',
      'binary_sensor.living_smoke',
    ],
    'weather': ['weather.home'],
  },
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
      if (request.method == 'POST' &&
          request.url.path.contains('/room-comfort/') &&
          request.url.path.endsWith('/plan/refresh')) {
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

  testWidgets('clean install opens candidate-only comfort source editor', (
    tester,
  ) async {
    fixture.respond = (request) async {
      final path = request.url.path;
      if (request.method == 'POST' && path.endsWith('/plan/refresh')) {
        return fixture.json({
          'error': {'code': 'comfort_source_not_configured'},
        }, 409);
      }
      if (request.method == 'GET' && path.endsWith('/configuration/setup')) {
        return fixture.json({
          'schemaVersion': 1,
          'services': [_setupService()],
          'rooms': [_setupResource('2' * 32, 'room', 'Living room')],
          'areas': [_setupResource('3' * 32, 'resource', 'Downstairs')],
        });
      }
      if (request.method == 'GET' && path.endsWith('/configuration')) {
        return fixture.json({
          'error': {'code': 'comfort_source_not_configured'},
        }, 409);
      }
      if (request.method == 'GET' &&
          path.contains('/configuration/entities/')) {
        return fixture.json(_entityCatalog());
      }
      return fixture.defaultResponse(request);
    };
    await mount(tester, RoomComfortRoute(gateCurrent: () => true));
    final setup = find.text('Configure verified sources').last;
    expect(setup, findsOneWidget);
    await tester.tap(setup);
    await tester.pumpAndSettle();

    expect(find.text('Room comfort sources'), findsOneWidget);
    expect(find.text('Verified Home Assistant'), findsNothing);
    final setupScroll = find.descendant(
      of: find.byType(ListView),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('comfort-policy-targetTemperatureMilliC')),
      400,
      scrollable: setupScroll.first,
    );
    await tester.pump();
    final policyFields = tester.widgetList<CupertinoTextField>(
      find.byType(CupertinoTextField),
    );
    expect(policyFields, isNotEmpty);
    expect(policyFields.every((field) => field.controller?.text == ''), isTrue);

    await tester.fling(setupScroll.first, const Offset(0, 3000), 2000);
    await tester.pumpAndSettle();
    final servicePicker = find.byKey(const ValueKey('comfort-setup-service'));
    expect(servicePicker, findsOneWidget);
    await tester.tap(
      find.descendant(
        of: servicePicker,
        matching: find.byType(CupertinoButton),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Verified Home Assistant'), findsOneWidget);
    await tester.tap(
      find.ancestor(
        of: find.text('Verified Home Assistant'),
        matching: find.byType(CupertinoActionSheetAction),
      ),
    );
    await tester.pumpAndSettle();
    final entityCalls = fixture.calls.where(
      (call) =>
          call.method == 'GET' &&
          call.url.path.contains('/configuration/entities/'),
    );
    expect(
      entityCalls,
      hasLength(1),
      reason: fixture.calls
          .map((call) => '${call.method} ${call.url.path}')
          .join('\n'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('inline editor saves through the current route authority', (
    tester,
  ) async {
    fixture.respond = (request) async {
      final path = request.url.path;
      if (request.method == 'POST' && path.endsWith('/plan/refresh')) {
        return fixture.json({'schemaVersion': 1, 'plan': _plan()});
      }
      if (request.method == 'GET' && path.endsWith('/configuration/setup')) {
        return fixture.json({
          'schemaVersion': 1,
          'services': [_setupService()],
          'rooms': [_setupResource('2' * 32, 'room', 'Living room')],
          'areas': [_setupResource('3' * 32, 'resource', 'Downstairs')],
        });
      }
      if (request.method == 'GET' && path.endsWith('/configuration')) {
        return fixture.json({
          'schemaVersion': 1,
          'configuration': _sourceConfiguration(),
        });
      }
      if (request.method == 'GET' &&
          path.contains('/configuration/entities/')) {
        return fixture.json(_entityCatalog());
      }
      if (request.method == 'PUT' && path.endsWith('/configuration')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['expectedRevision'], 4);
        expect(body['serviceId'], '4' * 32);
        expect(body['rooms'], hasLength(1));
        return fixture.json({
          'schemaVersion': 1,
          'configuration': _sourceConfiguration(5),
        });
      }
      return fixture.defaultResponse(request);
    };
    await mount(tester, RoomComfortRoute(gateCurrent: () => true));
    await tester.tap(find.byKey(const ValueKey('comfort-setup')));
    await tester.pumpAndSettle();
    expect(find.text('Room comfort sources'), findsOneWidget);
    expect(find.text('Verified Home Assistant'), findsOneWidget);

    final setupScroll = find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('comfort-setup-save')),
      500,
      scrollable: setupScroll,
    );
    await tester.tap(find.byKey(const ValueKey('comfort-setup-save')));
    await tester.pumpAndSettle();

    expect(find.byType(RoomComfortScreen), findsOneWidget);
    expect(
      fixture.calls.where(
        (call) =>
            call.method == 'PUT' && call.url.path.endsWith('/configuration'),
      ),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });
}
