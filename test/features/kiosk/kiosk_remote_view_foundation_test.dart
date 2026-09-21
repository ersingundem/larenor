import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/kiosk/domain/kiosk_remote_view.dart';

const authority = KioskDeviceAuthority(
  coreId: 'core-main',
  homeId: 'home-main',
  accountId: 'account-admin',
  deviceId: 'tablet-wall',
  deviceRevision: 7,
  policyRevision: 11,
  sessionEpoch: 13,
  routeEpoch: 17,
  lifecycleEpoch: 19,
);

Map<String, Object?> metrics({
  String deviceId = 'tablet-wall',
  int deviceRevision = 7,
  int policyRevision = 11,
}) => {
  'schemaVersion': 1,
  'deviceId': deviceId,
  'deviceRevision': deviceRevision,
  'policyRevision': policyRevision,
  'sampleRevision': 23,
  'capturedAtElapsedMs': 45000,
  'batteryPercent': 82,
  'charging': true,
  'network': 'wifi',
  'appVersion': '1.2.3-beta.1',
  'appBuild': 42,
  'memoryUsedMb': 128,
  'memoryLimitMb': 512,
  'processUptimeSeconds': 3600,
};

KioskRemoteViewContext context({
  KioskDeviceAuthority binding = authority,
  bool foreground = true,
  bool routeVisible = true,
  bool interactionActive = true,
  KioskScreenSensitivity sensitivity = KioskScreenSensitivity.ordinary,
  bool projectionConsentActive = true,
  int? projectionConsentRevision = 29,
}) => KioskRemoteViewContext(
  binding: binding,
  foreground: foreground,
  routeVisible: routeVisible,
  interactionActive: interactionActive,
  sensitivity: sensitivity,
  projectionConsentActive: projectionConsentActive,
  projectionConsentRevision: projectionConsentRevision,
);

final class Port implements KioskRemoteViewPort {
  Port({
    this.startGate,
    this.stopObserved = true,
    this.throwDuringReadback = false,
  });
  final Completer<void>? startGate;
  final bool stopObserved;
  final bool throwDuringReadback;
  int starts = 0, readbacks = 0, stops = 0;

  @override
  Set<KioskRemoteViewMode> get capabilities => const {
    KioskRemoteViewMode.appSurface,
    KioskRemoteViewMode.fullDeviceProjection,
  };

  @override
  Future<KioskRemotePortResult> start(
    KioskRemoteViewMode mode,
    String requestId,
    KioskRemoteViewContext trusted,
  ) async {
    starts++;
    await startGate?.future;
    return const KioskRemotePortResult(
      outcome: KioskRemotePortOutcome.accepted,
      receiptHandle: 'projection-local-1',
    );
  }

  @override
  Future<bool> readback(
    String receiptHandle,
    KioskRemoteViewMode mode,
    KioskRemoteViewContext trusted,
  ) async {
    readbacks++;
    if (throwDuringReadback) throw StateError('native readback unavailable');
    return true;
  }

  @override
  Future<bool> stop(
    String receiptHandle,
    KioskRemoteViewMode mode,
    KioskRemoteViewContext trusted,
  ) async {
    stops++;
    return stopObserved;
  }
}

void main() {
  test('device metrics are strict bounded read-only and publicly redacted', () {
    final snapshot = KioskDeviceSnapshot.fromChannel(
      metrics(),
      expected: authority,
      isCurrent: () => true,
      nowElapsedMs: 50000,
    );
    expect(snapshot.batteryPercent, 82);
    expect(snapshot.network, KioskNetworkClass.wifi);
    expect(snapshot.memoryUsedMb, 128);
    expect(snapshot.sampleRevision, 23);

    final public = jsonEncode(snapshot.toPublicJson());
    expect(public, contains('1.2.3-beta.1'));
    expect(public, isNot(contains('account-admin')));
    expect(public, isNot(contains('tablet-wall')));
    expect(public, isNot(contains('ssid')));
    expect(public, isNot(contains('ipAddress')));

    for (final invalid in [
      {...metrics(), 'ssid': 'private-network'},
      {...metrics(), 'batteryPercent': 101},
      {...metrics(), 'memoryUsedMb': 513},
      metrics(deviceRevision: 8),
      {...metrics(), 'network': '192.168.1.20'},
      {...metrics(), 'capturedAtElapsedMs': 1000},
    ]) {
      expect(
        () => KioskDeviceSnapshot.fromChannel(
          invalid,
          expected: authority,
          isCurrent: () => true,
          nowElapsedMs: 50000,
        ),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test(
    'app surface and full projection have separate fail-closed authority',
    () {
      final port = Port();
      final controller = KioskRemoteViewController(
        port: port,
        isCurrent: (candidate) => candidate == authority,
        requestIds: () => '0123456789abcdef0123456789abcdef',
      );

      expect(
        controller
            .prepare(
              KioskRemoteViewMode.appSurface,
              context(
                projectionConsentActive: false,
                projectionConsentRevision: null,
              ),
            )
            .status,
        KioskRemoteViewStatus.needsConfirmation,
      );
      controller.invalidate();

      for (final rejected in [
        context(
          projectionConsentActive: false,
          projectionConsentRevision: null,
        ),
        context(sensitivity: KioskScreenSensitivity.pin),
        context(sensitivity: KioskScreenSensitivity.credentials),
        context(sensitivity: KioskScreenSensitivity.unknown),
        context(foreground: false),
        context(routeVisible: false),
        context(interactionActive: false),
        context(
          binding: const KioskDeviceAuthority(
            coreId: 'core-main',
            homeId: 'home-main',
            accountId: 'account-admin',
            deviceId: 'tablet-wall',
            deviceRevision: 8,
            policyRevision: 11,
            sessionEpoch: 13,
            routeEpoch: 17,
            lifecycleEpoch: 19,
          ),
        ),
      ]) {
        expect(
          controller
              .prepare(KioskRemoteViewMode.fullDeviceProjection, rejected)
              .status,
          KioskRemoteViewStatus.denied,
        );
      }
      expect(port.starts, 0);
    },
  );

  test(
    'projection starts once and consent loss stops without replay',
    () async {
      final gate = Completer<void>();
      final port = Port(startGate: gate, stopObserved: false);
      final controller = KioskRemoteViewController(
        port: port,
        isCurrent: (candidate) => candidate == authority,
        requestIds: () => '0123456789abcdef0123456789abcdef',
      );
      final preview = controller.prepare(
        KioskRemoteViewMode.fullDeviceProjection,
        context(),
      );
      final pending = controller.confirm(preview, context());
      expect(
        (await controller.confirm(preview, context())).status,
        KioskRemoteViewStatus.unconfirmed,
      );
      expect(port.starts, 1);
      gate.complete();
      final active = await pending;
      expect(active.status, KioskRemoteViewStatus.active);
      expect(port.starts, 1);
      expect(port.readbacks, 1);

      final consentEnded = context(
        projectionConsentActive: false,
        projectionConsentRevision: null,
      );
      final stopped = await controller.reconcile(consentEnded);
      expect(stopped.status, KioskRemoteViewStatus.unconfirmed);
      expect(port.stops, 1);
      expect(
        (await controller.reconcile(consentEnded)).status,
        KioskRemoteViewStatus.unconfirmed,
      );
      expect(port.stops, 1);
      expect(
        (await controller.confirm(preview, context())).status,
        isNot(KioskRemoteViewStatus.active),
      );
      expect(port.starts, 1);
      expect(
        jsonEncode(stopped.toPublicJson()),
        isNot(contains('projection-local-1')),
      );
    },
  );
  test(
    'stale start is compensated once and delayed confirmation expires',
    () async {
      var current = true;
      var now = DateTime.utc(2026, 9, 21);
      final gate = Completer<void>();
      final port = Port(startGate: gate);
      final controller = KioskRemoteViewController(
        port: port,
        isCurrent: (_) => current,
        requestIds: () => '0123456789abcdef0123456789abcdef',
        now: () => now,
      );
      final preview = controller.prepare(
        KioskRemoteViewMode.fullDeviceProjection,
        context(),
      );
      final pending = controller.confirm(preview, context());
      current = false;
      gate.complete();
      expect((await pending).status, KioskRemoteViewStatus.unconfirmed);
      expect(port.starts, 1);
      expect(port.readbacks, 0);
      expect(port.stops, 1);

      current = true;
      controller.invalidate();
      final delayed = controller.prepare(
        KioskRemoteViewMode.fullDeviceProjection,
        context(),
      );
      now = now.add(const Duration(seconds: 31));
      expect(
        (await controller.confirm(delayed, context())).status,
        KioskRemoteViewStatus.denied,
      );
      expect(port.starts, 1);
    },
  );

  test('accepted start with unreadable readback is compensated once', () async {
    final port = Port(throwDuringReadback: true);
    final controller = KioskRemoteViewController(
      port: port,
      isCurrent: (candidate) => candidate == authority,
      requestIds: () => '0123456789abcdef0123456789abcdef',
    );
    final preview = controller.prepare(
      KioskRemoteViewMode.fullDeviceProjection,
      context(),
    );

    final receipt = await controller.confirm(preview, context());

    expect(receipt.status, KioskRemoteViewStatus.unconfirmed);
    expect(receipt.reasonCode, 'start_unconfirmed');
    expect(port.starts, 1);
    expect(port.readbacks, 1);
    expect(port.stops, 1);
    expect(
      (await controller.confirm(preview, context())).status,
      KioskRemoteViewStatus.unconfirmed,
    );
    expect(port.starts, 1);
    expect(port.stops, 1);
  });
}
