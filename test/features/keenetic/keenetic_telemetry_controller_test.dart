import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/keenetic/data/keenetic_client.dart';
import 'package:larenor/features/keenetic/data/keenetic_telemetry.dart';
import 'package:larenor/features/keenetic/providers/keenetic_telemetry_controller.dart';

import 'keenetic_telemetry_test.dart' show fixtureConfig, telemetryResponse;

Future<void> flush(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump();
  }
}

void main() {
  testWidgets(
    'creation is inert; duplicate demands share reads, last disposal stops polling',
    (tester) async {
      var logins = 0, batches = 0;
      var now = DateTime.utc(2026);
      final client = KeeneticClient(
        config: fixtureConfig,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/auth')) {
            logins++;
          } else {
            batches++;
          }
          return telemetryResponse(request);
        }),
      );
      final controller = KeeneticTelemetryController(
        client: client,
        now: () => now,
      );
      addTearDown(controller.dispose);
      expect(logins, 0);
      expect(batches, 0);
      final first = controller.register(
        const KeeneticMetricRequest(KeeneticMetricKind.internetStatus),
      );
      final second = controller.register(
        const KeeneticMetricRequest(KeeneticMetricKind.internetStatus),
      );
      await flush(tester);
      expect(logins, 1);
      expect(batches, 1);
      expect(controller.snapshot.internet.value!.internet, isTrue);
      first();
      now = now.add(const Duration(seconds: 31));
      await tester.pump(const Duration(seconds: 31));
      await flush(tester);
      expect(batches, 2);
      second();
      await tester.pump(const Duration(minutes: 2));
      expect(batches, 2);
      controller.dispose();
    },
  );
  testWidgets(
    'background pauses IO, clears rate baseline, resume starts with unknown speed',
    (tester) async {
      var requests = 0, bytes = 100;
      var tick = Duration.zero;
      final client = KeeneticClient(
        config: fixtureConfig,
        httpClient: MockClient((request) async {
          requests++;
          return telemetryResponse(request, rx: bytes);
        }),
      );
      final controller = KeeneticTelemetryController(
        client: client,
        monotonicNow: () => tick,
      );
      addTearDown(controller.dispose);
      final remove = controller.register(
        const KeeneticMetricRequest(
          KeeneticMetricKind.wanTraffic,
          interfaceId: 'GigabitEthernet1',
        ),
      );
      await flush(tester);
      expect(
        controller
            .snapshot
            .traffic['GigabitEthernet1']!
            .value!
            .receiveBytesPerSecond,
        isNull,
      );
      bytes = 150;
      tick = const Duration(seconds: 5);
      await tester.pump(const Duration(seconds: 5));
      await flush(tester);
      expect(
        controller
            .snapshot
            .traffic['GigabitEthernet1']!
            .value!
            .receiveBytesPerSecond,
        10,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final pausedCalls = requests;
      await tester.pump(const Duration(minutes: 1));
      expect(requests, pausedCalls);
      expect(controller.snapshot.isPaused, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      bytes = 250;
      tick = const Duration(seconds: 65);
      await flush(tester);
      expect(
        controller
            .snapshot
            .traffic['GigabitEthernet1']!
            .value!
            .receiveBytesPerSecond,
        isNull,
      );
      remove();
      controller.dispose();
    },
  );
  testWidgets(
    'a slow read never overlaps; queued new demand is fetched after it completes',
    (tester) async {
      final pending = Completer<http.Response>();
      var batches = 0, active = 0, maxActive = 0;
      final client = KeeneticClient(
        config: fixtureConfig,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/auth')) {
            return telemetryResponse(request);
          }
          active++;
          if (active > maxActive) maxActive = active;
          batches++;
          final response = batches == 1
              ? await pending.future
              : telemetryResponse(request);
          active--;
          return response;
        }),
      );
      final controller = KeeneticTelemetryController(client: client);
      addTearDown(controller.dispose);
      final one = controller.register(
        const KeeneticMetricRequest(KeeneticMetricKind.internetStatus),
      );
      await flush(tester);
      final two = controller.register(
        const KeeneticMetricRequest(KeeneticMetricKind.connectedDevices),
      );
      controller.refresh();
      controller.refresh();
      expect(batches, 1);
      pending.complete(
        http.Response(
          jsonEncode([
            {
              'internet': {
                'status': {'internet': true},
              },
            },
          ]),
          200,
        ),
      );
      await flush(tester);
      expect(maxActive, 1);
      expect(batches, 2);
      expect(controller.snapshot.hosts.value!.knownHosts, 2);
      one();
      two();
      controller.dispose();
    },
  );
  testWidgets(
    'permission failure retains stale values and stops timer; explicit refresh recovers',
    (tester) async {
      var reject = false, batches = 0;
      final client = KeeneticClient(
        config: fixtureConfig,
        httpClient: MockClient((request) async {
          if (!request.url.path.endsWith('/auth')) {
            batches++;
            if (reject) return http.Response('private server message', 403);
          }
          return telemetryResponse(request);
        }),
      );
      final controller = KeeneticTelemetryController(client: client);
      addTearDown(controller.dispose);
      final remove = controller.register(
        const KeeneticMetricRequest(KeeneticMetricKind.internetStatus),
      );
      await flush(tester);
      reject = true;
      controller.refresh();
      await flush(tester);
      expect(controller.snapshot.internet.isStale, isTrue);
      expect(
        controller.snapshot.internet.issue,
        KeeneticReadFailure.permission,
      );
      final before = batches;
      await tester.pump(const Duration(minutes: 2));
      expect(batches, before);
      reject = false;
      controller.refresh();
      await flush(tester);
      expect(controller.snapshot.internet.succeeded, isTrue);
      remove();
      controller.dispose();
    },
  );
  testWidgets('last listener removal ignores a delayed old response', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    final client = KeeneticClient(
      config: fixtureConfig,
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/auth')) {
          return telemetryResponse(request);
        }
        return pending.future;
      }),
    );
    final controller = KeeneticTelemetryController(client: client);
    addTearDown(controller.dispose);
    final remove = controller.register(
      const KeeneticMetricRequest(KeeneticMetricKind.internetStatus),
    );
    await flush(tester);
    remove();
    pending.complete(
      http.Response(
        jsonEncode([
          {
            'internet': {
              'status': {'internet': true},
            },
          },
        ]),
        200,
      ),
    );
    await flush(tester);
    expect(controller.snapshot.internet.value, isNull);
    controller.dispose();
  });
}
