import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/navigation/presentation/routines_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const _fixtures = [
  HaEntity(
    entityId: 'scene.evening',
    state: 'scening',
    attributes: {'friendly_name': 'Akşam Işığı'},
  ),
  HaEntity(
    entityId: 'script.movie_night',
    state: 'off',
    attributes: {'friendly_name': 'Film gecesi'},
  ),
  HaEntity(
    entityId: 'light.kitchen',
    state: 'off',
    attributes: {'friendly_name': 'Kitchen lamp'},
  ),
  HaEntity(
    entityId: 'automation.arriving',
    state: 'on',
    attributes: {'friendly_name': 'Arrival'},
  ),
];

class _Entities extends Entities {
  _Entities({this.initial = _fixtures, this.pending, this.fail = false});
  final List<HaEntity> initial;
  final Completer<Map<String, HaEntity>>? pending;
  bool fail;
  int reads = 0;
  int toggles = 0;
  @override
  Future<Map<String, HaEntity>> build() async {
    reads++;
    if (fail) throw StateError('private connection detail');
    return pending?.future ??
        {for (final entity in initial) entity.entityId: entity};
  }

  void replace(List<HaEntity> items) =>
      state = AsyncData({for (final entity in items) entity.entityId: entity});
  @override
  Future<void> toggle(HaEntity entity) async => toggles++;
}

Future<void> _show(
  WidgetTester tester,
  _Entities entities, {
  List<String>? requests,
}) async {
  tester.view.physicalSize = const Size(500, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final rest = HaRestClient(
    baseUrl: 'http://ha.invalid',
    token: 'test',
    httpClient: MockClient((request) async {
      requests?.add('${request.method} ${request.url.path}');
      return http.Response('[]', 200);
    }),
  );
  addTearDown(rest.dispose);
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (context, state) => const RoutinesScreen()),
      GoRoute(
        path: '/entities/:entityId',
        builder: (context, state) => CupertinoPageScaffold(
          child: Center(
            child: Text('Review ${state.pathParameters['entityId']}'),
          ),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      retry: (count, error) => null,
      overrides: [
        entitiesProvider.overrideWith(() => entities),
        haRestClientProvider.overrideWith((ref) => rest),
      ],
      child: CupertinoApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  testWidgets(
    'only scenes and scripts are listed and tapping reviews without executing',
    (tester) async {
      final entities = _Entities();
      final requests = <String>[];
      await _show(tester, entities, requests: requests);
      expect(find.text('Akşam Işığı'), findsOneWidget);
      expect(find.text('Film gecesi'), findsOneWidget);
      expect(find.text('Kitchen lamp'), findsNothing);
      expect(find.text('Arrival'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('routine-scene.evening')));
      await tester.pumpAndSettle();
      expect(find.text('Review scene.evening'), findsOneWidget);
      expect(entities.toggles, 0);
      expect(requests, isEmpty);
    },
  );

  testWidgets('search matches Turkish names and entity identifiers locally', (
    tester,
  ) async {
    final entities = _Entities();
    final requests = <String>[];
    await _show(tester, entities, requests: requests);
    await tester.enterText(
      find.byType(CupertinoSearchTextField),
      'aksam isigi',
    );
    await tester.pumpAndSettle();
    expect(find.text('Akşam Işığı'), findsOneWidget);
    expect(find.text('Film gecesi'), findsNothing);
    await tester.enterText(
      find.byType(CupertinoSearchTextField),
      'movie_night',
    );
    await tester.pumpAndSettle();
    expect(find.text('Akşam Işığı'), findsNothing);
    expect(find.text('Film gecesi'), findsOneWidget);
    expect(entities.reads, 1);
    expect(requests, isEmpty);
  });

  testWidgets('scene and script filters do not execute either domain', (
    tester,
  ) async {
    final entities = _Entities();
    await _show(tester, entities);
    final filter = find.byKey(const ValueKey('routines-filter'));
    await tester.tap(find.descendant(of: filter, matching: find.text('Scene')));
    await tester.pumpAndSettle();
    expect(find.text('Akşam Işığı'), findsOneWidget);
    expect(find.text('Film gecesi'), findsNothing);
    await tester.tap(
      find.descendant(of: filter, matching: find.text('Script')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Akşam Işığı'), findsNothing);
    expect(find.text('Film gecesi'), findsOneWidget);
    expect(entities.toggles, 0);
  });

  testWidgets('live removals and empty search results are distinguished', (
    tester,
  ) async {
    final entities = _Entities();
    await _show(tester, entities);
    await tester.enterText(
      find.byType(CupertinoSearchTextField),
      'not a routine',
    );
    await tester.pumpAndSettle();
    expect(find.text('No matching results'), findsOneWidget);
    entities.replace([]);
    await tester.pumpAndSettle();
    expect(find.text('No scenes or scripts are available.'), findsOneWidget);
    expect(find.byKey(const ValueKey('routine-scene.evening')), findsNothing);
  });

  testWidgets(
    'loading does not claim routines are absent and errors have a safe retry',
    (tester) async {
      final pending = Completer<Map<String, HaEntity>>();
      final entities = _Entities(pending: pending);
      await _show(tester, entities);
      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
      expect(find.text('No scenes or scripts are available.'), findsNothing);
      pending.completeError(StateError('private connection detail'));
      await tester.pumpAndSettle();
      expect(find.textContaining('private connection detail'), findsNothing);
      expect(find.text('Error'), findsOneWidget);
      expect(find.text('No scenes or scripts are available.'), findsNothing);
      expect(find.text('Retry'), findsOneWidget);
    },
  );

  testWidgets(
    'retry reloads an unavailable routine collection without writes',
    (tester) async {
      final entities = _Entities(fail: true);
      final requests = <String>[];
      await _show(tester, entities, requests: requests);
      expect(find.text('Error'), findsOneWidget);
      entities.fail = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Akşam Işığı'), findsOneWidget);
      expect(entities.reads, 2);
      expect(entities.toggles, 0);
      expect(requests, isEmpty);
    },
  );

  testWidgets('unrelated live sensor updates do not rebuild routine controls', (
    tester,
  ) async {
    final entities = _Entities();
    await _show(tester, entities);
    final searchBefore = tester.widget<CupertinoSearchTextField>(
      find.byType(CupertinoSearchTextField),
    );
    entities.replace([
      ..._fixtures,
      const HaEntity(entityId: 'sensor.temperature', state: '24'),
    ]);
    await tester.pump();
    expect(
      identical(
        searchBefore,
        tester.widget<CupertinoSearchTextField>(
          find.byType(CupertinoSearchTextField),
        ),
      ),
      isTrue,
    );
    entities.replace([
      _fixtures.first.copyWith(
        attributes: {'friendly_name': 'New evening name'},
      ),
    ]);
    await tester.pump();
    expect(find.text('New evening name'), findsOneWidget);
    expect(find.text('Akşam Işığı'), findsNothing);
  });

  testWidgets('a large collection builds only the visible rows', (
    tester,
  ) async {
    final entities = _Entities(
      initial: [
        for (var index = 0; index < 1000; index++)
          HaEntity(
            entityId: 'scene.routine_$index',
            state: 'unknown',
            attributes: {
              'friendly_name': 'Routine ${index.toString().padLeft(4, '0')}',
            },
          ),
      ],
    );
    await _show(tester, entities);
    expect(find.byType(CupertinoListTile).evaluate().length, lessThan(30));
    expect(find.text('Routine 0000'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
