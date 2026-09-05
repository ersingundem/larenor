import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/health/data/health_monitor.dart';
import 'package:larenor/features/health/data/integration_health.dart';
import 'package:larenor/features/keenetic/data/keenetic_client.dart';
import 'package:larenor/features/keenetic/data/keenetic_config.dart';
import 'package:larenor/features/keenetic/data/keenetic_telemetry.dart';

const fixtureConfig = KeeneticConfig(
  baseUrl: 'http://router.test/proxy',
  username: 'fixture',
  password: 'not-a-real-password',
);
Map<String, Object?> fixtureSource(String key) => switch (key) {
  'version' => {'model': 'Hero', 'release': '4.0'},
  'system' => {'cpuload': 8, 'memory': '100/400', 'uptime': '60'},
  'interface' => {
    'GigabitEthernet1': {
      'type': 'GigabitEthernet',
      'state': 'up',
      'link': 'up',
      'address': '192.0.2.1',
    },
    'WifiMaster0/AccessPoint0': {'type': 'AccessPoint', 'state': 'up'},
  },
  'internet' => {
    'status': {
      'internet': 'yes',
      'reliable': 'no',
      'dns-accessible': false,
      'gateway': {'interface': 'GigabitEthernet1', 'address': '192.0.2.1'},
    },
  },
  'ip' => {
    'hotspot': {
      'host': [
        {'mac': 'aa:bb', 'active': true, 'via': 'GigabitEthernet1'},
        {'mac': 'cc:dd'},
      ],
    },
  },
  _ => {},
};
http.Response telemetryResponse(
  http.Request request, {
  int rx = 100,
  int tx = 10,
}) {
  if (request.url.path.endsWith('/auth')) {
    return http.Response(
      '',
      200,
      headers: {'set-cookie': 'session=fixture; Path=/'},
    );
  }
  final body = jsonDecode(request.body);
  if (body is List) {
    return http.Response(
      jsonEncode([
        for (final command in body)
          {
            for (final key in (command as Map).keys)
              key: fixtureSource(key as String),
          },
      ]),
      200,
    );
  }
  return http.Response(
    jsonEncode({
      'interface': [
        for (final row in body['interface'])
          {
            'name': row['name'],
            'stat': {'rxbytes': rx, 'txbytes': tx},
          },
      ],
    }),
    200,
  );
}

void main() {
  test('all metrics use fixed show bodies; slash IDs stay JSON and unknown hosts stay unknown', () async {
    final requests = <http.Request>[];
    final client = KeeneticClient(
      config: fixtureConfig,
      httpClient: MockClient((request) async {
        requests.add(request);
        return telemetryResponse(request);
      }),
    );
    addTearDown(client.dispose);
    final result = await client.readTelemetry(
      KeeneticTelemetryDemand(
        kinds: KeeneticMetricKind.values,
        interfaceIds: ['WifiMaster0/AccessPoint0'],
      ),
    );
    expect(requests.map((r) => r.url.path), everyElement('/proxy/rci/show'));
    expect(requests.map((r) => r.method), everyElement('POST'));
    expect(jsonDecode(requests[0].body), [
      {'version': {}},
      {'system': {}},
      {'interface': {}},
      {
        'internet': {'status': {}},
      },
      {
        'ip': {'hotspot': {}},
      },
    ]);
    expect(jsonDecode(requests[1].body), {
      'interface': [
        {'name': 'WifiMaster0/AccessPoint0', 'stat': {}},
      ],
    });
    expect(result.resources.value!.memoryPercent, 25);
    expect(result.internet.value!.internet, isTrue);
    expect(result.internet.value!.reliable, isFalse);
    expect(result.hosts.value!.knownHosts, 2);
    expect(result.hosts.value!.activeHosts, isNull);
    expect(result.hosts.value!.unknownActivityHosts, 1);
    expect(result.traffic.values.single.value!.receivedBytes, 100);
    expect(result.traffic.values.single.value!.receiveBytesPerSecond, isNull);
  });

  test(
    'unverified selectors never reach a statistics request and cap is four',
    () async {
      var statCalls = 0;
      final client = KeeneticClient(
        config: fixtureConfig,
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body);
          if (body is Map) statCalls++;
          return http.Response(
            jsonEncode([
              {
                'interface': {
                  for (var i = 0; i < 8; i++) 'wan$i': {'type': 'PPPoE'},
                },
              },
            ]),
            200,
          );
        }),
      );
      addTearDown(client.dispose);
      final result = await client.readTelemetry(
        KeeneticTelemetryDemand(
          kinds: [KeeneticMetricKind.wanTraffic],
          interfaceIds: ['unknown', 'bad\nsystem reboot'],
        ),
      );
      expect(statCalls, 0);
      expect(
        result.traffic.values.map((r) => r.issue),
        everyElement(KeeneticReadFailure.selectionRequired),
      );
    },
  );

  test('at most four current inventory selectors are sent; returned identity must match', () async {
    List<dynamic>? selectors;
    final client = KeeneticClient(
      config: fixtureConfig,
      httpClient: MockClient((request) async {
        final body = jsonDecode(request.body);
        if (body is List) {
          return http.Response(
            jsonEncode([
              {
                'interface': {
                  for (var i = 0; i < 6; i++) 'wan$i': {'type': 'PPPoE'},
                },
              },
            ]),
            200,
          );
        }
        selectors = body['interface'] as List;
        return http.Response(
          jsonEncode({
            'interface': [
              for (final row in selectors!)
                {
                  'name': row['name'] == 'wan0'
                      ? 'another-interface'
                      : row['name'],
                  'stat': {'rxbytes': 10, 'txbytes': 20},
                },
            ],
          }),
          200,
        );
      }),
    );
    addTearDown(client.dispose);
    final result = await client.readTelemetry(
      KeeneticTelemetryDemand(
        kinds: [KeeneticMetricKind.wanTraffic],
        interfaceIds: [for (var i = 0; i < 6; i++) 'wan$i'],
      ),
    );
    expect(selectors, hasLength(4));
    expect(result.traffic['wan0']!.issue, KeeneticReadFailure.invalidResponse);
    expect(result.traffic['wan1']!.succeeded, isTrue);
    expect(
      result.traffic['wan4']!.issue,
      KeeneticReadFailure.selectionRequired,
    );
    expect(
      result.traffic['wan5']!.issue,
      KeeneticReadFailure.selectionRequired,
    );
  });

  test('traffic capability requires a successful statistics read', () {
    final snapshot = KeeneticTelemetrySnapshot(
      accountGeneration: Object(),
      interfaces: KeeneticReading(value: [KeeneticInterface(id: 'wan')]),
      traffic: {
        'wan': const KeeneticReading(issue: KeeneticReadFailure.unsupported),
      },
    );
    expect(
      snapshot.capability(KeeneticMetricKind.interfaces),
      KeeneticCapabilityState.supported,
    );
    expect(
      snapshot.capability(KeeneticMetricKind.wanTraffic),
      KeeneticCapabilityState.unsupported,
    );
  });

  test('partial command error preserves sibling data and health failure, no private message', () async {
    final monitor = HealthMonitor();
    final health = monitor.bind(IntegrationId.keenetic, configured: true);
    addTearDown(monitor.dispose);
    final client = KeeneticClient(
      config: fixtureConfig,
      healthSession: health,
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode([
            {'version': fixtureSource('version')},
            {'system': fixtureSource('system')},
            {
              'internet': {
                'status': {'status': 'error', 'message': 'secret-private-host'},
              },
            },
          ]),
          200,
        );
      }),
    );
    addTearDown(client.dispose);
    final result = await client.readTelemetry(
      KeeneticTelemetryDemand(
        kinds: [
          KeeneticMetricKind.routerResources,
          KeeneticMetricKind.internetStatus,
        ],
      ),
    );
    expect(result.resources.succeeded, isTrue);
    expect(result.internet.issue, KeeneticReadFailure.rejected);
    expect(result.internet.value, isNull);
    expect(monitor.read(IntegrationId.keenetic).lastSuccessfulRead, isNotNull);
    expect(monitor.read(IntegrationId.keenetic).failure, HealthFailure.server);
  });

  for (final value in <Object>[
    {},
    {'host': null},
    {
      'host': [null],
    },
    {
      'host': [
        {'mac': 'a'},
        {'mac': 'a'},
      ],
    },
  ]) {
    test('malformed hosts never become empty: $value', () async {
      final client = KeeneticClient(
        config: fixtureConfig,
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode([
              {
                'ip': {'hotspot': value},
              },
            ]),
            200,
          ),
        ),
      );
      addTearDown(client.dispose);
      final result = await client.readTelemetry(
        KeeneticTelemetryDemand(kinds: [KeeneticMetricKind.connectedDevices]),
      );
      expect(result.hosts.value, isNull);
      expect(result.hosts.issue, KeeneticReadFailure.invalidResponse);
    });
  }
  test('explicit empty host list is verified zero', () {
    final summary = KeeneticHostSummary.fromJson([]);
    expect(summary.activeHosts, 0);
    expect(summary.knownHosts, 0);
  });
  test(
    'counter parser rejects negative/fractional/nonfinite/imprecise values',
    () {
      for (final value in [
        -1,
        1.5,
        double.infinity,
        9007199254740992,
        'invalid',
      ]) {
        expect(keeneticCounter(value), isNull);
      }
      expect(keeneticCounter('123'), 123);
    },
  );

  test('traffic uses monotonic deltas; reset, duplicate, reboot, sleep and new account are unknown', () {
    final sampler = KeeneticTrafficSampler();
    KeeneticTrafficSample sample(int bytes, {int? stamp}) =>
        KeeneticTrafficSample(
          interfaceId: 'wan',
          receivedBytes: bytes,
          sentBytes: bytes,
          routerTimestamp: stamp,
        );
    expect(
      sampler.add(sample(100), Duration.zero).receiveBytesPerSecond,
      isNull,
    );
    expect(
      sampler
          .add(sample(150), const Duration(seconds: 5))
          .receiveBytesPerSecond,
      10,
    );
    expect(
      sampler
          .add(sample(150), const Duration(seconds: 10))
          .receiveBytesPerSecond,
      0,
    );
    expect(
      sampler
          .add(sample(10), const Duration(seconds: 15))
          .receiveBytesPerSecond,
      isNull,
    );
    expect(
      sampler
          .add(sample(50), const Duration(seconds: 50))
          .receiveBytesPerSecond,
      isNull,
    );
    sampler.reset();
    expect(
      sampler
          .add(sample(900), const Duration(seconds: 55))
          .receiveBytesPerSecond,
      isNull,
    );
    sampler.add(
      sample(1000, stamp: 1),
      const Duration(seconds: 60),
      uptimeSeconds: 100,
    );
    expect(
      sampler
          .add(
            sample(2000, stamp: 1),
            const Duration(seconds: 65),
            uptimeSeconds: 101,
          )
          .receiveBytesPerSecond,
      isNull,
    );
    expect(
      sampler
          .add(
            sample(3000, stamp: 2),
            const Duration(seconds: 70),
            uptimeSeconds: 1,
          )
          .receiveBytesPerSecond,
      isNull,
    );
  });
}
