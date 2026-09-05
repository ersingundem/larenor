import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/dashboard/presentation/tiles/climate_tile.dart';
import 'package:larenor/features/dashboard/presentation/tiles/media_player_tile.dart';
import 'package:larenor/features/dashboard/presentation/tiles/scene_tile.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/ha_tools/domain/ha_action.dart';
import 'package:larenor/features/ha_tools/presentation/ha_actions_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

class _Entities extends Entities {
  _Entities(this.initial);
  final HaEntity initial;
  @override
  Future<Map<String, HaEntity>> build() async => {initial.entityId: initial};
  void replace(HaEntity entity) => state = AsyncData({entity.entityId: entity});
  void reload() {
    // ignore: invalid_use_of_internal_member
    state = const AsyncLoading<Map<String, HaEntity>>().copyWithPrevious(state);
  }
}

class _Connection extends ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async => null;
  void replaceAccount() => state = const AsyncData(
    HaConnectionConfig(baseUrl: 'http://second.invalid', token: 'test-token'),
  );
}

TileConfig _tile(HaEntity entity, {String id = 'tile'}) => TileConfig(
  id: id,
  type: switch (entity.domain) {
    'scene' => TileType.scene,
    'climate' => TileType.climate,
    _ => TileType.mediaPlayer,
  },
  x: 0,
  y: 0,
  width: 2,
  height: 2,
  entityId: entity.entityId,
);

Widget _widget(HaEntity entity, {String id = 'tile'}) =>
    switch (entity.domain) {
      'scene' => SceneTile(tile: _tile(entity, id: id)),
      'climate' => ClimateTile(tile: _tile(entity, id: id)),
      _ => MediaPlayerTile(tile: _tile(entity, id: id)),
    };

const _scene = HaEntity(
  entityId: 'scene.evening',
  state: 'scening',
  attributes: {'friendly_name': 'Evening'},
);
const _media = HaEntity(
  entityId: 'media_player.living',
  state: 'paused',
  attributes: {
    'friendly_name': 'Living room',
    'supported_features': 1 | 4 | 16 | 32 | 16384,
    'volume_level': 0.2,
  },
);
const _climate = HaEntity(
  entityId: 'climate.living',
  state: 'heat',
  attributes: {
    'friendly_name': 'Thermostat',
    'supported_features': 1,
    'temperature': 20,
    'current_temperature': 19,
    'min_temp': 10,
    'max_temp': 30,
    'target_temp_step': 0.5,
  },
);
const _mediaServices = [
  'media_play',
  'media_pause',
  'media_previous_track',
  'media_next_track',
  'volume_set',
];

void main() {
  final requests = <http.Request>[];
  late _Entities entities;
  late _Connection connection;
  late AppInteractionController interaction;
  late GlobalKey<NavigatorState> navigator;
  late ValueNotifier<bool> visible;

  Future<void> mount(
    WidgetTester tester,
    HaEntity entity,
    List<String> services, {
    Future<http.Response> Function(http.Request)? response,
    bool duplicate = false,
    double tileHeight = 240,
    double textScale = 1,
    String language = 'en',
  }) async {
    requests.clear();
    interaction = AppInteractionController();
    navigator = GlobalKey<NavigatorState>();
    visible = ValueNotifier(true);
    addTearDown(interaction.dispose);
    addTearDown(visible.dispose);
    entities = _Entities(entity);
    connection = _Connection();
    final client = HaRestClient(
      baseUrl: 'http://ha.invalid',
      token: 'test',
      httpClient: MockClient((request) async {
        requests.add(request);
        return response == null ? http.Response('[]', 200) : response(request);
      }),
    );
    addTearDown(client.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          entitiesProvider.overrideWith(() => entities),
          connectionConfigProvider.overrideWith(() => connection),
          haRestClientProvider.overrideWith((ref) => client),
          haWebSocketClientProvider.overrideWith((ref) => null),
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
          navigatorKey: navigator,
          builder: (context, child) => AppInteractionScope(
            controller: interaction,
            child: ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (_, enabled, _) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(textScale)),
                child: TickerMode(enabled: enabled, child: child!),
              ),
            ),
          ),
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CupertinoPageScaffold(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 240,
                    height: tileHeight,
                    child: _widget(entity),
                  ),
                  if (duplicate)
                    SizedBox(
                      width: 240,
                      height: 240,
                      child: _widget(entity, id: 'second'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  CupertinoSlider volume(WidgetTester tester) =>
      tester.widget(find.byType(CupertinoSlider));
  Finder dialFinder() => find.descendant(
    of: find.byKey(const ValueKey('climate-dial-climate.living')),
    matching: find.byWidgetPredicate(
      (widget) => widget is GestureDetector && widget.onPanUpdate != null,
    ),
  );
  GestureDetector dial(WidgetTester tester) => tester.widget(dialFinder());
  Map<String, dynamic> body() =>
      jsonDecode(requests.last.body) as Map<String, dynamic>;

  testWidgets(
    'climate slider announces one target and preserves current reading',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await mount(tester, _climate, ['set_temperature']);
        final node = tester.getSemantics(
          find.byKey(const ValueKey('climate-dial-climate.living')),
        );
        expect(node.label, 'Thermostat, Target temperature');
        expect(node.value, '20.0°');
        expect(node.hint, 'Current: 19.0°');
        expect(node.getSemanticsData().flagsCollection.isSlider, isTrue);
        expect(
          node.getSemanticsData().hasAction(ui.SemanticsAction.increase),
          isTrue,
        );
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'climate dial keyboard changes one step and respects inactive scope',
    (tester) async {
      await mount(tester, _climate, ['set_temperature']);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(requests, hasLength(1));
      expect(body()['temperature'], 20.5);
      interaction.setActive(false);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(requests, hasLength(1));
    },
  );

  for (final language in ['en', 'tr']) {
    testWidgets('climate dial text fits 2x in compact cell ($language)', (
      tester,
    ) async {
      await mount(
        tester,
        _climate,
        ['set_temperature'],
        tileHeight: 98,
        textScale: 2,
        language: language,
      );
      expect(tester.takeException(), isNull);
      expect(requests, isEmpty);
    });
  }

  testWidgets('idle then wake never renews a captured scene callback', (
    tester,
  ) async {
    await mount(tester, _scene, ['turn_on']);
    VoidCallback tap() => tester
        .widget<GestureDetector>(
          find.byKey(const ValueKey('scene-action-scene.evening')),
        )
        .onTap!;
    final old = tap();
    interaction.setActive(false);
    interaction.setActive(
      true,
    ); // Deliberately no frame between idle/wake/callback.
    old();
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    tap()();
    await tester.pumpAndSettle();
    expect(requests.length, 1);
  });

  testWidgets(
    'media volume gesture from before idle cannot commit after wake',
    (tester) async {
      await mount(tester, _media, _mediaServices);
      final old = volume(tester);
      old.onChangeStart!(0.2);
      old.onChanged!(0.8);
      interaction.setActive(false);
      interaction.setActive(true);
      old.onChangeEnd!(0.8);
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      expect(volume(tester).value, 0.2);
      volume(tester).onChangeStart!(0.2);
      volume(tester).onChangeEnd!(0.6);
      await tester.pumpAndSettle();
      expect(requests.length, 1);
      expect(body()['volume_level'], 0.6);
    },
  );

  testWidgets('climate pan ending after idle cannot dispatch an old draft', (
    tester,
  ) async {
    await mount(tester, _climate, ['set_temperature']);
    final old = dial(tester);
    final size = tester.getSize(dialFinder());
    old.onPanStart!(
      DragStartDetails(localPosition: Offset(0, size.height / 2)),
    );
    interaction.setActive(false);
    interaction.setActive(true);
    old.onPanEnd!(DragEndDetails());
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(find.text('20.0°'), findsOneWidget);
    dial(tester).onPanStart!(
      DragStartDetails(localPosition: Offset(0, size.height / 2)),
    );
    dial(tester).onPanEnd!(DragEndDetails());
    await tester.pumpAndSettle();
    expect(requests.length, 1);
  });

  testWidgets(
    'background expires scene actions even after returning to resumed',
    (tester) async {
      await mount(tester, _scene, ['turn_on']);
      final old = tester
          .widget<GestureDetector>(
            find.byKey(const ValueKey('scene-action-scene.evening')),
          )
          .onTap!;
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      old();
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
    },
  );

  testWidgets('covered and hidden routes cannot keep scene callbacks alive', (
    tester,
  ) async {
    await mount(tester, _scene, ['turn_on']);
    VoidCallback tap() => tester
        .widget<GestureDetector>(
          find.byKey(const ValueKey('scene-action-scene.evening')),
        )
        .onTap!;
    final covered = tap();
    unawaited(
      navigator.currentState!.push(
        CupertinoPageRoute<void>(
          builder: (_) =>
              const CupertinoPageScaffold(child: Text('Other page')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    covered();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    covered();
    expect(requests, isEmpty);
    final hidden = tap();
    visible.value = false;
    await tester.pump();
    hidden();
    visible.value = true;
    await tester.pumpAndSettle();
    hidden();
    expect(requests, isEmpty);
    tap()();
    await tester.pumpAndSettle();
    expect(requests.length, 1);
  });

  testWidgets(
    'retained entity loading cannot dispatch through a saved tile action',
    (tester) async {
      await mount(tester, _scene, ['turn_on']);
      final old = tester
          .widget<GestureDetector>(
            find.byKey(const ValueKey('scene-action-scene.evening')),
          )
          .onTap!;
      entities.reload();
      old(); // No frame: the previous entity remains in AsyncValue.value.
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
    },
  );
  testWidgets('scene taps use the target guard and show server acceptance', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    await mount(tester, _scene, ['turn_on'], response: (_) => pending.future);
    final action = tester
        .widget<GestureDetector>(
          find.byKey(const ValueKey('scene-action-scene.evening')),
        )
        .onTap!;
    action();
    action();
    action();
    await tester.pump();
    expect(requests.length, 1);
    expect(requests.single.url.path, '/api/services/scene/turn_on');
    expect(body(), {'entity_id': 'scene.evening'});
    pending.complete(http.Response('[]', 200));
    await tester.pumpAndSettle();
    expect(find.text('Home Assistant accepted the request'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'duplicate scene tiles share one pending target and catch the second request',
    (tester) async {
      final pending = Completer<http.Response>();
      await mount(
        tester,
        _scene,
        ['turn_on'],
        duplicate: true,
        response: (_) => pending.future,
      );
      final tiles = find.byKey(const ValueKey('scene-action-scene.evening'));
      tester.widget<GestureDetector>(tiles.at(0)).onTap!();
      tester.widget<GestureDetector>(tiles.at(1)).onTap!();
      await tester.pump();
      expect(requests.length, 1);
      expect(
        find.text('A request is already pending for this device.'),
        findsOneWidget,
      );
      pending.complete(http.Response('[]', 200));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('scene requires a real scene and an advertised service', (
    tester,
  ) async {
    await mount(tester, _scene, []);
    expect(
      tester
          .widget<GestureDetector>(
            find.byKey(const ValueKey('scene-action-scene.evening')),
          )
          .onTap,
      isNull,
    );
    expect(requests, isEmpty);
  });

  testWidgets(
    'media volume previews locally and sends one snapped value at gesture end',
    (tester) async {
      final pending = Completer<http.Response>();
      await mount(
        tester,
        _media,
        _mediaServices,
        response: (_) => pending.future,
      );
      volume(tester).onChangeStart!(0.2);
      for (var i = 0; i < 100; i++) {
        volume(tester).onChanged!(i / 100);
      }
      await tester.pump();
      expect(requests, isEmpty);
      volume(tester).onChangeEnd!(0.737);
      volume(tester).onChangeEnd!(0.9);
      await tester.pump();
      expect(requests.length, 1);
      expect(body(), {
        'entity_id': 'media_player.living',
        'volume_level': 0.74,
      });
      expect(volume(tester).onChanged, isNull);
      pending.complete(http.Response('[]', 200));
      await tester.pumpAndSettle();
      expect(volume(tester).value, 0.2);
    },
  );

  testWidgets('media controls require both feature flags and services', (
    tester,
  ) async {
    await mount(
      tester,
      _media.copyWith(
        attributes: {'supported_features': 4 | 16, 'volume_level': 0.2},
      ),
      ['media_play', 'media_previous_track'],
    );
    expect(
      find.byKey(const ValueKey('media-tile-media_previous_track')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('media-tile-media_play')), findsNothing);
    expect(find.byType(CupertinoSlider), findsNothing);
    entities.replace(_media.copyWith(state: 'unavailable'));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoButton), findsNothing);
    expect(requests, isEmpty);
  });

  testWidgets('media gesture cannot commit into a newly selected account', (
    tester,
  ) async {
    await mount(tester, _media, _mediaServices);
    final old = volume(tester);
    old.onChangeStart!(0.2);
    old.onChanged!(0.8);
    connection.replaceAccount();
    await tester.pumpAndSettle();
    old.onChangeEnd!(0.8);
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(volume(tester).value, 0.2);
  });

  testWidgets('climate dial sends once on pan end and obeys target step', (
    tester,
  ) async {
    await mount(tester, _climate, ['set_temperature']);
    final size = tester.getSize(dialFinder());
    dial(tester).onPanStart!(
      DragStartDetails(localPosition: Offset(size.width, size.height / 2)),
    );
    for (var i = 0; i < 50; i++) {
      dial(tester).onPanUpdate!(
        DragUpdateDetails(
          localPosition: Offset(0, size.height / 2),
          globalPosition: Offset.zero,
        ),
      );
    }
    await tester.pump();
    expect(requests, isEmpty);
    dial(tester).onPanEnd!(DragEndDetails());
    await tester.pumpAndSettle();
    expect(requests.length, 1);
    expect(body(), {'entity_id': 'climate.living', 'temperature': 25.0});
    expect(find.text('20.0°'), findsOneWidget);
  });

  testWidgets(
    'cancelled climate gestures do not send or retain a draft target',
    (tester) async {
      await mount(tester, _climate, ['set_temperature']);
      final size = tester.getSize(dialFinder());
      dial(tester).onPanStart!(
        DragStartDetails(localPosition: Offset(0, size.height / 2)),
      );
      await tester.pump();
      dial(tester).onPanCancel!();
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      expect(find.text('20.0°'), findsOneWidget);
    },
  );

  testWidgets(
    'invalid climate ranges and non-finite temperatures cannot send',
    (tester) async {
      await mount(tester, _climate, ['set_temperature']);
      for (final attributes in [
        {..._climate.attributes, 'min_temp': 30, 'max_temp': 10},
        {..._climate.attributes, 'temperature': double.nan},
        {..._climate.attributes, 'target_temp_step': 0},
        {..._climate.attributes, 'target_temp_step': double.infinity},
        {..._climate.attributes, 'min_temp': -1e308, 'max_temp': 1e308},
        {..._climate.attributes, 'supported_features': 2},
      ]) {
        entities.replace(_climate.copyWith(attributes: attributes));
        await tester.pumpAndSettle();
        expect(dialFinder(), findsNothing);
        expect(tester.takeException(), isNull);
      }
      expect(requests, isEmpty);
    },
  );

  testWidgets('climate account change cancels an old gesture callback', (
    tester,
  ) async {
    await mount(tester, _climate, ['set_temperature']);
    final size = tester.getSize(dialFinder());
    final old = dial(tester);
    old.onPanStart!(
      DragStartDetails(localPosition: Offset(0, size.height / 2)),
    );
    connection.replaceAccount();
    await tester.pumpAndSettle();
    old.onPanEnd!(DragEndDetails());
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final entity in [_scene, _media, _climate]) {
    testWidgets(
      '${entity.domain} action failures are caught and never print server response secrets',
      (tester) async {
        await mount(tester, entity, switch (entity.domain) {
          'scene' => ['turn_on'],
          'climate' => ['set_temperature'],
          _ => _mediaServices,
        }, response: (_) async => http.Response('private server secret', 403));
        switch (entity.domain) {
          case 'scene':
            await tester.tap(
              find.byKey(const ValueKey('scene-action-scene.evening')),
            );
          case 'media_player':
            await tester.tap(
              find.byKey(const ValueKey('media-tile-media_play')),
            );
          case 'climate':
            final size = tester.getSize(dialFinder());
            dial(tester).onPanStart!(
              DragStartDetails(localPosition: Offset(0, size.height / 2)),
            );
            dial(tester).onPanEnd!(DragEndDetails());
        }
        await tester.pumpAndSettle();
        expect(requests.length, 1);
        expect(find.text('The request could not be completed'), findsOneWidget);
        expect(find.textContaining('private server secret'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final entity in [_scene, _media, _climate]) {
    testWidgets('${entity.domain} controls fit an imported 98px grid cell', (
      tester,
    ) async {
      await mount(tester, entity, switch (entity.domain) {
        'scene' => ['turn_on'],
        'climate' => ['set_temperature'],
        _ => _mediaServices,
      }, tileHeight: 98);
      expect(tester.takeException(), isNull);
      final view = find.byType(SingleChildScrollView).first;
      await tester.drag(view, const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'a slow action completing after the tile is disposed cannot update its UI',
    (tester) async {
      final pending = Completer<http.Response>();
      await mount(tester, _scene, ['turn_on'], response: (_) => pending.future);
      await tester.tap(
        find.byKey(const ValueKey('scene-action-scene.evening')),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      pending.complete(http.Response('private server secret', 500));
      await tester.pumpAndSettle();
      expect(requests.length, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
