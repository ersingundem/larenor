import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/dashboard/presentation/widgets/entity_controls.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/ha_tools/domain/ha_action.dart';
import 'package:larenor/features/ha_tools/presentation/ha_actions_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

void main() {
  final requests = <http.Request>[];

  Future<void> mount(
    WidgetTester tester,
    HaEntity entity,
    List<String> services, {
    Future<http.Response> Function(http.Request)? response,
  }) async {
    requests.clear();
    final client = HaRestClient(
      baseUrl: 'http://ha.test',
      token: 'example',
      httpClient: MockClient((request) async {
        requests.add(request);
        return response == null ? http.Response('[]', 200) : response(request);
      }),
    );
    addTearDown(client.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          haRestClientProvider.overrideWith((ref) => client),
          haActionsProvider.overrideWith(
            (ref) async => [
              for (final service in services)
                HaAction(
                  domain: entity.domain,
                  service: service,
                  metadata: const {},
                ),
            ],
          ),
        ],
        child: CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: CupertinoPageScaffold(
            child: SafeArea(
              child: SingleChildScrollView(
                child: EntityControls(entity: entity),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  CupertinoSlider slider(WidgetTester tester, String field) =>
      tester.widget(find.byKey(ValueKey('entity-control-$field')));
  Map<String, dynamic> body() =>
      jsonDecode(requests.last.body) as Map<String, dynamic>;

  testWidgets(
    'cover controls require both features and current server services',
    (tester) async {
      await mount(
        tester,
        const HaEntity(
          entityId: 'cover.example',
          state: 'open',
          attributes: {'supported_features': 1 | 2 | 4, 'current_position': 50},
        ),
        ['open_cover', 'stop_cover', 'set_cover_position'],
      );
      expect(
        find.byKey(const ValueKey('entity-control-open_cover')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('entity-control-close_cover')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('entity-control-stop_cover')),
        findsNothing,
      );
      final control = slider(tester, 'position');
      control.onChanged!(73);
      await tester.pump();
      expect(requests, isEmpty);
      slider(tester, 'position').onChangeEnd!(73);
      await tester.pumpAndSettle();
      expect(body(), {'entity_id': 'cover.example', 'position': 73});
      expect(body()['position'], isA<int>());
    },
  );

  testWidgets('cover unknown position is not presented as closed', (
    tester,
  ) async {
    await mount(
      tester,
      const HaEntity(
        entityId: 'cover.example',
        state: 'open',
        attributes: {'supported_features': 1 | 4},
      ),
      ['open_cover', 'set_cover_position'],
    );
    expect(find.byType(CupertinoSlider), findsNothing);
    await tester.tap(find.byKey(const ValueKey('entity-control-open_cover')));
    await tester.pumpAndSettle();
    expect(requests.single.url.path, '/api/services/cover/open_cover');
  });

  testWidgets('climate ranges send both bounds and enforce ordered targets', (
    tester,
  ) async {
    await mount(
      tester,
      const HaEntity(
        entityId: 'climate.example',
        state: 'heat_cool',
        attributes: {
          'supported_features': 2,
          'target_temp_low': 19.5,
          'target_temp_high': 24,
          'min_temp': 7,
          'max_temp': 35,
          'target_temp_step': 0.5,
        },
      ),
      ['set_temperature'],
    );
    expect(
      find.byKey(const ValueKey('entity-control-temperature')),
      findsNothing,
    );
    slider(tester, 'target_temp_low').onChangeEnd!(30);
    await tester.pumpAndSettle();
    expect(body(), {
      'entity_id': 'climate.example',
      'target_temp_low': 24.0,
      'target_temp_high': 24.0,
    });
    slider(tester, 'target_temp_high').onChangeEnd!(22.2);
    await tester.pumpAndSettle();
    expect(body()['target_temp_high'], 22.0);
    expect(body()['target_temp_low'], 19.5);
  });

  testWidgets(
    'climate mode uses reported options without requiring a feature flag',
    (tester) async {
      await mount(
        tester,
        const HaEntity(
          entityId: 'climate.example',
          state: 'heat',
          attributes: {
            'supported_features': 0,
            'hvac_modes': ['off', 'heat', 'cool'],
            'fan_modes': ['auto'],
          },
        ),
        ['set_hvac_mode', 'set_fan_mode'],
      );
      expect(find.text('Fan mode'), findsNothing);
      await tester.tap(find.text('Mode'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CupertinoActionSheetAction, 'cool'));
      await tester.pumpAndSettle();
      expect(body(), {'entity_id': 'climate.example', 'hvac_mode': 'cool'});
    },
  );

  testWidgets('fan fractional speed steps emit an integer percentage once', (
    tester,
  ) async {
    await mount(
      tester,
      const HaEntity(
        entityId: 'fan.example',
        state: 'on',
        attributes: {
          'supported_features': 1,
          'percentage': 33,
          'percentage_step': 100 / 3,
        },
      ),
      ['set_percentage'],
    );
    slider(tester, 'percentage').onChanged!(65);
    await tester.pump();
    expect(requests, isEmpty);
    slider(tester, 'percentage').onChangeEnd!(65);
    await tester.pumpAndSettle();
    expect(body(), {'entity_id': 'fan.example', 'percentage': 67});
    expect(body()['percentage'], isA<int>());
  });

  testWidgets(
    'number uses reported min max and step even for YAML definitions',
    (tester) async {
      await mount(
        tester,
        const HaEntity(
          entityId: 'input_number.example',
          state: '1.2',
          attributes: {'min': 0.2, 'max': 2.2, 'step': 0.2, 'editable': false},
        ),
        ['set_value'],
      );
      slider(tester, 'value').onChangeEnd!(1.33);
      await tester.pumpAndSettle();
      expect(body()['value'], 1.4);
      expect(requests.single.url.path, '/api/services/input_number/set_value');
    },
  );

  testWidgets('select unknown state still permits an explicit valid choice', (
    tester,
  ) async {
    await mount(
      tester,
      const HaEntity(
        entityId: 'select.example',
        state: 'unknown',
        attributes: {
          'options': ['Quiet mode', 'Boost'],
        },
      ),
      ['select_option'],
    );
    await tester.tap(find.text('Option'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(CupertinoActionSheetAction, 'Quiet mode'),
    );
    await tester.pumpAndSettle();
    expect(body(), {'entity_id': 'select.example', 'option': 'Quiet mode'});
  });

  testWidgets(
    'lock with zero features waits for unlock confirmation and includes entered code',
    (tester) async {
      await mount(
        tester,
        const HaEntity(
          entityId: 'lock.example',
          state: 'locked',
          attributes: {'supported_features': 0, 'code_format': r'^\d{4}$'},
        ),
        ['lock', 'unlock'],
      );
      await tester.tap(find.byKey(const ValueKey('entity-control-unlock')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(requests, isEmpty);
      await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Cancel'));
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      await tester.tap(find.byKey(const ValueKey('entity-control-unlock')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(CupertinoTextField), '1234');
      await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Unlock'));
      await tester.pumpAndSettle();
      expect(body(), {'entity_id': 'lock.example', 'code': '1234'});
    },
  );

  testWidgets(
    'media playback and volume follow their independent feature flags',
    (tester) async {
      await mount(
        tester,
        const HaEntity(
          entityId: 'media_player.example',
          state: 'playing',
          attributes: {'supported_features': 1 | 4 | 32, 'volume_level': 0.3},
        ),
        [
          'media_pause',
          'media_play',
          'media_next_track',
          'media_previous_track',
          'volume_set',
        ],
      );
      expect(
        find.byKey(const ValueKey('entity-control-media_play')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('entity-control-media_previous_track')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('entity-control-media_pause')),
      );
      await tester.pumpAndSettle();
      expect(requests.last.url.path, '/api/services/media_player/media_pause');
      slider(tester, 'volume_level').onChangeEnd!(0.42);
      await tester.pumpAndSettle();
      expect(body(), {
        'entity_id': 'media_player.example',
        'volume_level': 0.42,
      });
    },
  );

  testWidgets(
    'pending commands block duplicates and failed commands recover controls',
    (tester) async {
      final reply = Completer<http.Response>();
      await mount(
        tester,
        const HaEntity(
          entityId: 'cover.example',
          state: 'closed',
          attributes: {'supported_features': 1},
        ),
        ['open_cover'],
        response: (_) => reply.future,
      );
      final button = tester.widget<CupertinoButton>(
        find.byKey(const ValueKey('entity-control-open_cover')),
      );
      button.onPressed!();
      button.onPressed!();
      await tester.pump();
      expect(requests, hasLength(1));
      expect(
        tester
            .widget<CupertinoButton>(
              find.byKey(const ValueKey('entity-control-open_cover')),
            )
            .onPressed,
        isNull,
      );
      reply.complete(
        http.Response('{"message":"Device rejected the command"}', 400),
      );
      await tester.pumpAndSettle();
      expect(find.text('The request could not be completed'), findsOneWidget);
      expect(find.textContaining('Device rejected the command'), findsNothing);
      expect(
        tester
            .widget<CupertinoButton>(
              find.byKey(const ValueKey('entity-control-open_cover')),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'unavailable entities cannot dispatch even if the service exists',
    (tester) async {
      await mount(
        tester,
        const HaEntity(entityId: 'lock.example', state: 'unavailable'),
        ['unlock'],
      );
      expect(
        tester
            .widget<CupertinoButton>(
              find.byKey(const ValueKey('entity-control-unlock')),
            )
            .onPressed,
        isNull,
      );
      expect(requests, isEmpty);
    },
  );

  testWidgets('invalid numeric ranges never create an invalid slider', (
    tester,
  ) async {
    await mount(
      tester,
      const HaEntity(
        entityId: 'number.example',
        state: '5',
        attributes: {'min': 5, 'max': 5, 'step': 0},
      ),
      ['set_value'],
    );
    expect(find.byType(CupertinoSlider), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
