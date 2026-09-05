import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/keenetic/data/keenetic_telemetry.dart';
import 'package:larenor/features/keenetic/data/models/keenetic_router_status.dart';
import 'package:larenor/features/keenetic/presentation/keenetic_metric_presentation.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

void main() {
  late AppLocalizations l10n;
  setUpAll(
    () async => l10n = await AppLocalizations.delegate.load(const Locale('en')),
  );

  test(
    'measured zero differs from missing and rates convert bytes to SI bits',
    () {
      for (final invalid in [
        null,
        -1.0,
        double.nan,
        double.infinity,
        double.maxFinite,
      ]) {
        expect(formatKeeneticRate(invalid, l10n), l10n.commonUnknown);
      }
      expect(formatKeeneticRate(0, l10n), '0.0 bit/s');
      expect(formatKeeneticRate(12500000, l10n), '100.0 Mbit/s');
    },
  );

  test('unknown resources and active devices are never reported as zero', () {
    final snapshot = KeeneticTelemetrySnapshot(
      accountGeneration: 1,
      resources: const KeeneticReading(
        value: KeeneticRouterStatus(model: 'Fixture', cpuPercent: 0),
      ),
      hosts: KeeneticReading(
        value: KeeneticHostSummary(
          knownHosts: 4,
          unknownActivityHosts: 1,
          activeHosts: null,
        ),
      ),
    );
    final resources = KeeneticMetricPresentation.from(
      snapshot,
      const KeeneticMetricRequest(KeeneticMetricKind.routerResources),
      l10n,
    );
    expect(resources.lines[0].value, '0%');
    expect(resources.lines[1].value, l10n.commonUnknown);
    expect(resources.lines[2].value, l10n.commonUnknown);
    final hosts = KeeneticMetricPresentation.from(
      snapshot,
      const KeeneticMetricRequest(KeeneticMetricKind.connectedDevices),
      l10n,
    );
    expect(hosts.lines.map((line) => line.value), [
      l10n.commonUnknown,
      '4',
      '1',
    ]);
  });

  test('download naming requires fresh WAN evidence and never calls interface IP public', () {
    final now = DateTime.utc(2026, 9, 5);
    const request = KeeneticMetricRequest(
      KeeneticMetricKind.wanTraffic,
      interfaceId: 'ISP',
    );
    KeeneticTelemetrySnapshot snapshot(
      DateTime time, {
      KeeneticReadFailure? failure,
    }) => KeeneticTelemetrySnapshot(
      accountGeneration: 1,
      internet: KeeneticReading(
        readAt: time,
        issue: failure,
        value: const KeeneticInternetStatus(gatewayInterfaceId: 'ISP'),
      ),
      interfaces: KeeneticReading(
        value: [KeeneticInterface(id: 'ISP', address: '100.64.1.2')],
      ),
      traffic: {
        'ISP': KeeneticReading(
          readAt: now,
          value: const KeeneticTrafficSample(
            interfaceId: 'ISP',
            receiveBytesPerSecond: 12500000,
            sendBytesPerSecond: 0,
          ),
        ),
      },
    );
    final current = KeeneticMetricPresentation.from(
      snapshot(now),
      request,
      l10n,
      now: now,
    );
    expect(current.lines.first.label, l10n.keeneticDownloadRate);
    expect(current.lines[1].label, l10n.keeneticUploadRate);
    expect(current.lines[2], (
      label: l10n.keeneticInterfaceAddress,
      value: '100.64.1.2',
    ));
    for (final value in [
      snapshot(now.subtract(const Duration(seconds: 46))),
      snapshot(now.add(const Duration(seconds: 1))),
      snapshot(now, failure: KeeneticReadFailure.transport),
    ]) {
      final projection = KeeneticMetricPresentation.from(
        value,
        request,
        l10n,
        now: now,
      );
      expect(projection.lines.first.label, l10n.keeneticReceiveRate);
      expect(projection.lines[1].label, l10n.keeneticSendRate);
    }
  });

  test(
    'first sample is pending and retained failed measurement is marked stale',
    () {
      const request = KeeneticMetricRequest(
        KeeneticMetricKind.wanTraffic,
        interfaceId: 'ISP',
      );
      for (final issue in [null, KeeneticReadFailure.transport]) {
        final snapshot = KeeneticTelemetrySnapshot(
          accountGeneration: 1,
          traffic: {
            'ISP': KeeneticReading(
              readAt: DateTime.utc(2026, 9, 5),
              issue: issue,
              value: const KeeneticTrafficSample(
                interfaceId: 'ISP',
                receivedBytes: 1024,
                sentBytes: 0,
              ),
            ),
          },
        );
        final result = KeeneticMetricPresentation.from(snapshot, request, l10n);
        expect(result.lines.first.value, l10n.commonUnknown);
        expect(result.lines[4].value, '1.0 KiB');
        expect(result.awaitingSample, issue == null);
        expect(result.stale, issue != null);
        expect(result.issue, issue);
      }
    },
  );
}
