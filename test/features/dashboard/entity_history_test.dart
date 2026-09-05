import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/dashboard/data/entity_history.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/dashboard/presentation/tiles/history_tile.dart';
import 'package:larenor/features/dashboard/providers/entity_history_providers.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

final start = DateTime.utc(2026, 9, 4);
final end = DateTime.utc(2026, 9, 5);
Map<String, dynamic> point(String state, String time, {String? entityId}) => {
  'state': state,
  'last_changed': time,
  'entity_id': ?entityId,
};
EntityHistorySeries parse(List<Map<String, dynamic>> points) =>
    parseEntityHistory(
      [points],
      entityId: 'sensor.test',
      start: start,
      end: end,
    );
TileConfig tile(String id) => TileConfig(
  id: 'history',
  type: TileType.history,
  x: 0,
  y: 0,
  width: 2,
  height: 2,
  entityId: id,
);

void main() {
  test('unknown and nonfinite values become gaps; baseline and duplicate timestamps are deterministic', () {
    final series = parse([
      point('8', '2026-09-03T23:00:00Z'),
      point('12', '2026-09-04T01:00:00Z'),
      point('13', '2026-09-04T01:00:00Z'),
      point('unavailable', '2026-09-04T02:00:00Z'),
      point('NaN', '2026-09-04T03:00:00Z'),
      point('Infinity', '2026-09-04T04:00:00Z'),
      point('0', '2026-09-04T05:00:00Z'),
    ]);
    expect(series.points.map((value) => value.value), [
      8,
      13,
      null,
      null,
      null,
      0,
    ]);
    expect(series.points.first.time, start);
    expect(series.hasValues, isTrue);
    expect(parse([]).hasValues, isFalse);
    expect(
      parse([point('unknown', '2026-09-04T04:00:00Z')]).hasValues,
      isFalse,
    );
  });

  test('foreign entities, ambiguous/future timestamps and oversize data are rejected', () {
    for (final points in [
      [point('1', '2026-09-04T01:00:00Z', entityId: 'sensor.other')],
      [point('1', '2026-09-04T01:00:00')],
      [point('1', '2026-09-06T01:00:00Z')],
      List.generate(10001, (_) => point('1', '2026-09-04T01:00:00Z')),
    ]) {
      expect(() => parse(points), throwsFormatException);
    }
  });

  test('provider uses bounded structured history GET and old account completion cannot replace new values', () async {
    final pending = Completer<http.Response>();
    final started = Completer<void>();
    final sent = <http.Request>[];
    final old = HaRestClient(
      baseUrl: 'http://old.test/prefix',
      token: 'fixture-old',
      httpClient: MockClient((request) {
        sent.add(request);
        started.complete();
        return pending.future;
      }),
    );
    final next = HaRestClient(
      baseUrl: 'http://next.test',
      token: 'fixture-new',
      httpClient: MockClient(
        (request) async => http.Response(
          jsonEncode([
            [
              point(
                '42',
                DateTime.now()
                    .toUtc()
                    .subtract(const Duration(minutes: 5))
                    .toIso8601String(),
              ),
            ],
          ]),
          200,
        ),
      ),
    );
    final container = ProviderContainer(
      overrides: [haRestClientProvider.overrideWithValue(old)],
    );
    addTearDown(() {
      container.dispose();
      old.dispose();
      next.dispose();
    });
    final provider = entityHistoryProvider('sensor.test');
    container.listen(provider, (_, _) {});
    await started.future;
    await container.pump();
    expect(sent.single.method, 'GET');
    expect(sent.single.url.path, startsWith('/prefix/api/history/period/'));
    expect(sent.single.url.queryParameters['filter_entity_id'], 'sensor.test');
    expect(sent.single.url.queryParameters['end_time'], isNotEmpty);
    expect(sent.single.url.queryParameters['no_attributes'], '');
    container.updateOverrides([haRestClientProvider.overrideWithValue(next)]);
    await container.pump();
    final current = await container.read(provider.future);
    expect(current!.points.single.value, 42);
    pending.complete(
      http.Response(
        jsonEncode([
          [
            point(
              '1',
              DateTime.now()
                  .toUtc()
                  .subtract(const Duration(minutes: 5))
                  .toIso8601String(),
            ),
          ],
        ]),
        200,
      ),
    );
    await container.pump();
    expect(container.read(provider).value!.points.single.value, 42);
  });

  testWidgets(
    'hidden tiles do not read, entity replacement resolves fresh data and errors stay generic',
    (tester) async {
      final selection = ValueNotifier((id: 'sensor.first', visible: false));
      addTearDown(selection.dispose);
      var firstReads = 0;
      var secondReads = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            entitiesProvider.overrideWithBuild((ref, notifier) async => {}),
            entityHistoryProvider('sensor.first').overrideWith((ref) async {
              firstReads++;
              return parse([point('12', '2026-09-04T01:00:00Z')]);
            }),
            entityHistoryProvider('sensor.second').overrideWith((ref) async {
              secondReads++;
              throw StateError('private backend text');
            }),
          ],
          child: CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Center(
              child: ValueListenableBuilder(
                valueListenable: selection,
                builder: (context, value, _) => TickerMode(
                  enabled: value.visible,
                  child: SizedBox(
                    width: 160,
                    height: 180,
                    child: HistoryTile(tile: tile(value.id)),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(firstReads, 0);
      selection.value = (id: 'sensor.first', visible: true);
      await tester.pumpAndSettle();
      expect(firstReads, 1);
      expect(find.text('sensor.first'), findsOneWidget);
      selection.value = (id: 'sensor.second', visible: true);
      await tester.pumpAndSettle();
      expect(secondReads, 1);
      expect(find.text('sensor.second'), findsOneWidget);
      expect(find.text('sensor.first'), findsNothing);
      expect(find.text('Could not read service data'), findsOneWidget);
      expect(find.textContaining('private backend'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
