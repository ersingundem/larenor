import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/energy/data/energy_api.dart';
import 'package:larenor/features/energy/data/energy_period.dart';
import 'package:larenor/features/energy/domain/energy_models.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';

import '../ha_client/fake_socket.dart';
import 'energy_fixture.dart';

void main() {
  late FakeSocket socket;
  late HaWebSocketClient ws;
  late HaRestClient rest;
  late HaEnergyApi api;
  final requests = <http.Request>[];
  setUp(() async {
    socket = FakeSocket();
    requests.clear();
    ws = HaWebSocketClient(
      baseUrl: 'http://fixture.test',
      token: 'fixture',
      channelFactory: (_) => socket,
    )..connect();
    rest = HaRestClient(
      baseUrl: 'http://fixture.test',
      token: 'fixture',
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({'time_zone': 'UTC', 'currency': 'TRY'}),
          200,
        );
      }),
    );
    api = HaEnergyApi(rest: rest, ws: ws);
    await socket.authenticate();
  });
  tearDown(() {
    ws.dispose();
    rest.dispose();
  });
  Future<Map<String, dynamic>> result(
    Future<Object?> pending,
    Object? value,
  ) async {
    await flushEvents();
    final command = socket.sent.last;
    socket.emit({
      'type': 'result',
      'id': command['id'],
      'success': true,
      'result': value,
    });
    await pending;
    return command;
  }

  test('energy config, preferences, information and metadata use only authenticated read endpoints', () async {
    expect((await api.getConfig())['time_zone'], 'UTC');
    expect(requests.single.method, 'GET');
    expect(requests.single.url.path, '/api/config');
    expect(requests.single.headers['Authorization'], 'Bearer fixture');
    expect(
      (await result(api.getPreferences(), {}))['type'],
      'energy/get_prefs',
    );
    expect((await result(api.getInformation(), {}))['type'], 'energy/info');
    final metadata = await result(api.getMetadata(['sensor.grid']), []);
    expect(metadata['type'], 'recorder/get_statistics_metadata');
    expect(metadata['statistic_ids'], ['sensor.grid']);
    expect(socket.sent.map((command) => command['type']), [
      'auth',
      'subscribe_events',
      'energy/get_prefs',
      'energy/info',
      'recorder/get_statistics_metadata',
    ]);
  });
  test('wire request uses recorder change, kWh conversion and UTC end inside final local date', () async {
    final period = buildEnergyPeriod(
      'Europe/Berlin',
      DateTime.utc(2026, 3, 29, 12),
      EnergyRange.last7Days,
    );
    final command = await result(
      api.getStatistics(
        statisticIds: ['sensor.grid'],
        start: period.start,
        endInclusive: period.dailyRequestEnd,
        hourly: false,
      ),
      {},
    );
    expect(command['type'], 'recorder/statistics_during_period');
    expect(command['period'], 'day');
    expect(command['types'], ['change']);
    expect(command['units'], {'energy': 'kWh'});
    expect(
      DateTime.parse(command['end_time'] as String),
      period.endExclusive.subtract(const Duration(milliseconds: 1)),
    );
    expect((command['start_time'] as String).endsWith('Z'), isTrue);
    final hourly = await result(
      api.getStatistics(
        statisticIds: ['sensor.grid'],
        start: energyHourCeil(period.start).subtract(const Duration(hours: 1)),
        endInclusive: period.observedAt,
        hourly: true,
      ),
      {},
    );
    expect(hourly['period'], 'hour');
  });
  test('empty, duplicate, invalid or unbounded requests never send a recorder command', () {
    final before = socket.sent.length;
    for (final ids in [
      <String>[],
      ['sensor.grid', 'sensor.grid'],
      ['../private'],
      List.generate(129, (i) => 'sensor.$i'),
    ]) {
      expect(() => api.getMetadata(ids), throwsA(isA<EnergyException>()));
    }
    expect(
      () => api.getStatistics(
        statisticIds: ['sensor.grid'],
        start: energyNow,
        endInclusive: energyNow,
        hourly: true,
      ),
      throwsA(isA<EnergyException>()),
    );
    expect(
      () => api.getStatistics(
        statisticIds: ['sensor.grid'],
        start: energyNow,
        endInclusive: energyNow.add(const Duration(days: 10)),
        hourly: true,
      ),
      throwsA(isA<EnergyException>()),
    );
    expect(socket.sent, hasLength(before));
  });
}
