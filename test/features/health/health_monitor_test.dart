import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/health/data/health_monitor.dart';
import 'package:larenor/features/health/data/integration_health.dart';
import 'package:larenor/shared/network/transport_observation.dart';

void main() {
  late DateTime now;
  late HealthMonitor monitor;
  setUp(() {
    now = DateTime.utc(2026, 9, 5, 12);
    monitor = HealthMonitor(now: () => now);
  });
  tearDown(() => monitor.dispose());

  test(
    'saved configuration and HTTP contact do not prove a successful read',
    () {
      expect(
        monitor.read(IntegrationId.ha).statusAt(now),
        HealthStatus.notConfigured,
      );
      final session = monitor.bind(IntegrationId.ha, configured: true);
      expect(
        monitor.read(IntegrationId.ha).statusAt(now),
        HealthStatus.configured,
      );
      session.connecting();
      expect(
        monitor.read(IntegrationId.ha).statusAt(now),
        HealthStatus.connecting,
      );
      session.observeTransport(
        const TransportObservation(
          kind: TransportObservationKind.response,
          isRead: true,
          statusCode: 200,
        ),
      );
      session.observeTransport(
        const TransportObservation(
          kind: TransportObservationKind.completed,
          isRead: true,
          statusCode: 200,
        ),
      );
      final health = monitor.read(IntegrationId.ha);
      expect(health.statusAt(now), HealthStatus.reachable);
      expect(health.lastContact, now);
      expect(health.lastSuccessfulRead, isNull);
    },
  );

  test('401 and 403 are reachable but distinguish identity and permission', () {
    final session = monitor.bind(IntegrationId.ha, configured: true);
    for (final pair in {
      401: HealthStatus.authenticationRequired,
      403: HealthStatus.permissionDenied,
    }.entries) {
      session.observeTransport(
        TransportObservation(
          kind: TransportObservationKind.response,
          isRead: true,
          statusCode: pair.key,
        ),
      );
      expect(monitor.read(IntegrationId.ha).statusAt(now), pair.value);
      expect(monitor.read(IntegrationId.ha).lastContact, now);
    }
  });

  test('successful write cannot refresh read age or erase its auth fault', () {
    final session = monitor.bind(IntegrationId.ha, configured: true)
      ..readSucceeded();
    final readTime = now;
    session.failed(HealthFailure.authentication);
    now = now.add(const Duration(minutes: 10));
    session.observeTransport(
      const TransportObservation(
        kind: TransportObservationKind.response,
        isRead: false,
        statusCode: 200,
      ),
    );
    final health = monitor.read(IntegrationId.ha);
    expect(health.lastSuccessfulRead, readTime);
    expect(health.lastContact, now);
    expect(health.statusAt(now), HealthStatus.authenticationRequired);
    session.readSucceeded();
    expect(monitor.read(IntegrationId.ha).statusAt(now), HealthStatus.healthy);
  });

  test('read becomes stale by receipt time, not server entity timestamp', () {
    final session = monitor.bind(IntegrationId.ha, configured: true)
      ..readSucceeded();
    expect(monitor.read(IntegrationId.ha).dataIsFreshAt(now), isTrue);
    now = now.add(const Duration(minutes: 3));
    expect(monitor.read(IntegrationId.ha).statusAt(now), HealthStatus.stale);
    session.readSucceeded();
    expect(monitor.read(IntegrationId.ha).statusAt(now), HealthStatus.healthy);
  });

  test('live heartbeat keeps unchanged data fresh only after synchronized snapshot', () {
    final session = monitor.bind(IntegrationId.ha, configured: true)
      ..readSucceeded();
    now = now.add(const Duration(minutes: 3));
    session.liveConnected();
    session.liveContact();
    expect(monitor.read(IntegrationId.ha).statusAt(now), HealthStatus.stale);
    session.readSucceeded(synchronizesLiveSnapshot: true);
    now = now.add(const Duration(hours: 1));
    session.liveContact();
    expect(monitor.read(IntegrationId.ha).statusAt(now), HealthStatus.healthy);
    session.liveDisconnected();
    expect(monitor.read(IntegrationId.ha).statusAt(now), HealthStatus.stale);
    session.liveConnected();
    expect(monitor.read(IntegrationId.ha).statusAt(now), HealthStatus.stale);
  });

  test(
    'silent live connection ages out even if no disconnect event arrived',
    () {
      final session = monitor.bind(IntegrationId.ha, configured: true)
        ..liveConnected()
        ..readSucceeded(synchronizesLiveSnapshot: true);
      now = now.add(const Duration(minutes: 3));
      session.liveContact();
      expect(monitor.read(IntegrationId.ha).dataIsFreshAt(now), isTrue);
      now = now.add(const Duration(seconds: 76));
      expect(monitor.read(IntegrationId.ha).statusAt(now), HealthStatus.stale);
    },
  );

  test('closed and superseded clients cannot update the current account', () {
    final old = monitor.bind(IntegrationId.ha, configured: true)
      ..readSucceeded();
    old.close();
    final prior = monitor.read(IntegrationId.ha);
    old.failed(HealthFailure.authentication);
    expect(monitor.read(IntegrationId.ha), same(prior));
    final current = monitor.bind(IntegrationId.ha, configured: true);
    old.readSucceeded();
    expect(monitor.read(IntegrationId.ha).lastSuccessfulRead, isNull);
    current.readSucceeded();
    expect(monitor.read(IntegrationId.ha).statusAt(now), HealthStatus.healthy);
  });

  test('changed local config resets evidence before new client opens', () {
    final firstConfig = Object();
    final session = monitor.bind(
      IntegrationId.ha,
      configured: true,
      configurationIdentity: firstConfig,
    )..readSucceeded();
    monitor.synchronizeConfiguration(IntegrationId.ha, firstConfig);
    expect(monitor.read(IntegrationId.ha).lastSuccessfulRead, now);
    monitor.synchronizeConfiguration(IntegrationId.ha, Object());
    expect(
      monitor.read(IntegrationId.ha).statusAt(now),
      HealthStatus.configured,
    );
    session.readSucceeded();
    expect(monitor.read(IntegrationId.ha).lastSuccessfulRead, isNull);
    monitor.synchronizeConfiguration(IntegrationId.ha, null);
    expect(
      monitor.read(IntegrationId.ha).statusAt(now),
      HealthStatus.notConfigured,
    );
  });

  test('retry and timeout preserve last successful read evidence', () {
    final session = monitor.bind(IntegrationId.ha, configured: true)
      ..readSucceeded();
    session.observeTransport(
      const TransportObservation(
        kind: TransportObservationKind.failed,
        isRead: true,
        failure: TransportFailure.timeout,
      ),
    );
    expect(monitor.read(IntegrationId.ha).statusAt(now), HealthStatus.offline);
    session.retrying(3);
    expect(monitor.read(IntegrationId.ha).statusAt(now), HealthStatus.retrying);
    expect(monitor.read(IntegrationId.ha).lastSuccessfulRead, now);
    session.failed(HealthFailure.authentication);
    expect(
      monitor.read(IntegrationId.ha).statusAt(now),
      HealthStatus.authenticationRequired,
    );
  });

  test('late subscribers receive immutable current evidence', () async {
    monitor.bind(IntegrationId.ha, configured: true).readSucceeded();
    final states = await monitor.changes.first;
    expect(states[IntegrationId.ha]!.lastSuccessfulRead, now);
    expect(() => states.clear(), throwsUnsupportedError);
  });
}
