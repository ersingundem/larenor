import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/ha_tools/domain/ha_action.dart';
import 'package:larenor/features/ha_tools/presentation/ha_actions_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

final catalog = HaAction.parseCatalog([
  {
    'domain': 'light',
    'services': {
      'turn_on': {
        'name': 'Turn on',
        'target': <String, dynamic>{},
        'fields': {
          'brightness_pct': {
            'required': true,
            'selector': {
              'number': {'min': 0, 'max': 100},
            },
          },
          'advanced': {
            'fields': {
              'transition': {
                'selector': {'number': <String, dynamic>{}},
              },
            },
          },
        },
      },
    },
  },
  {
    'domain': 'weather',
    'services': {
      'get_forecasts': {
        'response': {'optional': false},
      },
    },
  },
  {
    'domain': 'homeassistant',
    'services': {
      'restart': <String, dynamic>{},
      'toggle': {'target': <String, dynamic>{}},
    },
  },
]);

class _Connection extends ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async =>
      const HaConnectionConfig(baseUrl: 'http://ha.test', token: 'fixture');
}

class _Entities extends Entities {
  @override
  Future<Map<String, HaEntity>> build() async => {
    'light.desk': const HaEntity(entityId: 'light.desk', state: 'on'),
  };
}

Widget app(Widget child, HaRestClient client) => ProviderScope(
  overrides: [
    connectionConfigProvider.overrideWith(_Connection.new),
    entitiesProvider.overrideWith(_Entities.new),
    haWebSocketClientProvider.overrideWith((ref) => null),
    haRestClientProvider.overrideWith((ref) => client),
    haActionsProvider.overrideWith((ref) async => catalog),
  ],
  child: CupertinoApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  ),
);

void main() {
  test(
    'server catalog retains response requirement and flattens field sections',
    () {
      final light = catalog.singleWhere((a) => a.domain == 'light');
      expect(light.fields.map((f) => f.name), ['brightness_pct', 'transition']);
      expect(light.supportsTarget, isTrue);
      expect(
        catalog.singleWhere((a) => a.domain == 'weather').requiresResponse,
        isTrue,
      );
      expect(parseJsonObject(''), isEmpty);
      expect(() => parseJsonObject('[]'), throwsFormatException);
    },
  );

  testWidgets('device scope exposes device actions without server restart', (
    tester,
  ) async {
    final client = HaRestClient(
      baseUrl: 'http://ha.test',
      token: 'test',
      httpClient: MockClient((_) async => http.Response('[]', 200)),
    );
    addTearDown(client.dispose);
    await tester.pumpWidget(
      app(const HaActionsScreen(entityId: 'light.desk'), client),
    );
    await tester.pumpAndSettle();
    expect(find.text('light.turn_on'), findsOneWidget);
    expect(find.text('homeassistant.toggle'), findsOneWidget);
    expect(find.text('homeassistant.restart'), findsNothing);
    expect(find.text('weather.get_forecasts'), findsNothing);
    await tester.enterText(find.byType(CupertinoSearchTextField), 'toggle');
    await tester.pumpAndSettle();
    expect(find.text('light.turn_on'), findsNothing);
  });

  testWidgets('action validates and sends typed data only after confirmation', (
    tester,
  ) async {
    final requests = <http.Request>[];
    final client = HaRestClient(
      baseUrl: 'http://ha.test',
      token: 'test',
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('[]', 200);
      }),
    );
    addTearDown(client.dispose);
    final action = catalog.singleWhere((a) => a.domain == 'light');
    await tester.pumpWidget(
      app(HaActionScreen(action: action, entityId: 'light.desk'), client),
    );
    await tester.pumpAndSettle();
    // Missing required brightness cannot execute a request.
    await tester.ensureVisible(find.widgetWithText(CupertinoButton, 'Run'));
    await tester.tap(find.widgetWithText(CupertinoButton, 'Run'));
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(find.textContaining('brightness_pct: required'), findsOneWidget);
    // JSON can provide typed values for any selector, including required ones.
    final advanced = find.byType(CupertinoTextField).last;
    await tester.enterText(advanced, '{"brightness_pct":42,"transition":2.5}');
    await tester.ensureVisible(find.widgetWithText(CupertinoButton, 'Run'));
    await tester.tap(find.widgetWithText(CupertinoButton, 'Run'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(requests, isEmpty);
    await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Run'));
    await tester.pumpAndSettle();
    expect(requests, hasLength(1));
    expect(jsonDecode(requests.single.body), {
      'brightness_pct': 42,
      'transition': 2.5,
      'entity_id': 'light.desk',
    });
    expect(requests.single.url.path, '/api/services/light/turn_on');
    expect(tester.takeException(), isNull);
  });
}
