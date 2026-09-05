import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../health/data/integration_health.dart';
import '../../health/presentation/health_labels.dart';
import '../data/keenetic_telemetry.dart';

typedef KeeneticMetricLine = ({String label, String value});

String keeneticMetricTitle(AppLocalizations l10n, KeeneticMetricKind kind) =>
    switch (kind) {
      KeeneticMetricKind.internetStatus => l10n.keeneticInternetStatus,
      KeeneticMetricKind.wanTraffic => l10n.keeneticTraffic,
      KeeneticMetricKind.connectedDevices => l10n.keeneticConnectedDevices,
      KeeneticMetricKind.routerResources => l10n.keeneticResources,
      KeeneticMetricKind.interfaces => l10n.keeneticInterfaces,
    };
IconData keeneticMetricIcon(KeeneticMetricKind kind) => switch (kind) {
  KeeneticMetricKind.internetStatus => CupertinoIcons.globe,
  KeeneticMetricKind.wanTraffic => CupertinoIcons.arrow_up_arrow_down,
  KeeneticMetricKind.connectedDevices => CupertinoIcons.device_laptop,
  KeeneticMetricKind.routerResources => CupertinoIcons.gauge,
  KeeneticMetricKind.interfaces => CupertinoIcons.square_stack_3d_up,
};

String keeneticReadFailureLabel(
  AppLocalizations l10n,
  KeeneticReadFailure failure,
) => switch (failure) {
  KeeneticReadFailure.authentication => healthFailureLabel(
    l10n,
    HealthFailure.authentication,
  ),
  KeeneticReadFailure.permission => healthFailureLabel(
    l10n,
    HealthFailure.permission,
  ),
  KeeneticReadFailure.transport => healthFailureLabel(
    l10n,
    HealthFailure.transport,
  ),
  KeeneticReadFailure.timeout => healthFailureLabel(
    l10n,
    HealthFailure.timeout,
  ),
  KeeneticReadFailure.invalidResponse => healthFailureLabel(
    l10n,
    HealthFailure.invalidResponse,
  ),
  KeeneticReadFailure.server => healthFailureLabel(l10n, HealthFailure.server),
  KeeneticReadFailure.unsupported => l10n.keeneticMetricUnsupported,
  KeeneticReadFailure.rejected => l10n.keeneticMetricRejected,
  KeeneticReadFailure.inactive => l10n.keeneticMetricPaused,
  KeeneticReadFailure.selectionRequired => l10n.keeneticChooseInterface,
};

String formatKeeneticRate(double? bytesPerSecond, AppLocalizations l10n) {
  if (bytesPerSecond == null ||
      !bytesPerSecond.isFinite ||
      bytesPerSecond < 0) {
    return l10n.commonUnknown;
  }
  var bits = bytesPerSecond * 8;
  if (!bits.isFinite) return l10n.commonUnknown;
  const units = ['bit/s', 'kbit/s', 'Mbit/s', 'Gbit/s', 'Tbit/s'];
  var index = 0;
  while (bits >= 1000 && index < units.length - 1) {
    bits /= 1000;
    index++;
  }
  return '${NumberFormat('0.0', l10n.localeName).format(bits)} ${units[index]}';
}

String _bytes(int? value, AppLocalizations l10n) {
  if (value == null || value < 0) return l10n.commonUnknown;
  var number = value.toDouble();
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
  var index = 0;
  while (number >= 1024 && index < units.length - 1) {
    number /= 1024;
    index++;
  }
  return '${NumberFormat('0.0', l10n.localeName).format(number)} ${units[index]}';
}

String _uptime(int? seconds, AppLocalizations l10n) {
  if (seconds == null || seconds < 0) return l10n.commonUnknown;
  final value = Duration(seconds: seconds);
  return [
    if (value.inDays > 0) '${value.inDays} ${l10n.keeneticUptimeDays}',
    if (value.inHours > 0) '${value.inHours % 24} ${l10n.keeneticUptimeHours}',
    '${value.inMinutes % 60} ${l10n.keeneticUptimeMinutes}',
  ].join(' ');
}

class KeeneticMetricPresentation {
  const KeeneticMetricPresentation({
    required this.lines,
    this.issue,
    this.readAt,
    this.stale = false,
    this.awaitingSample = false,
  });
  final List<KeeneticMetricLine> lines;
  final KeeneticReadFailure? issue;
  final DateTime? readAt;
  final bool stale, awaitingSample;

  factory KeeneticMetricPresentation.from(
    KeeneticTelemetrySnapshot snapshot,
    KeeneticMetricRequest request,
    AppLocalizations l10n, {
    DateTime? now,
  }) {
    String text(Object? value) => value?.toString() ?? l10n.commonUnknown;
    String flag(bool? value) => value == null
        ? l10n.commonUnknown
        : value
        ? l10n.keeneticReachable
        : l10n.keeneticUnreachable;
    String percent(int? value) =>
        value == null ? l10n.commonUnknown : '$value%';
    final selected = snapshot.interfaces.value
        ?.where((item) => item.id == request.interfaceId)
        .firstOrNull;
    final traffic = snapshot.traffic[request.interfaceId];
    final reading = switch (request.kind) {
      KeeneticMetricKind.internetStatus => snapshot.internet,
      KeeneticMetricKind.wanTraffic =>
        traffic ?? const KeeneticReading<KeeneticTrafficSample>(),
      KeeneticMetricKind.connectedDevices => snapshot.hosts,
      KeeneticMetricKind.routerResources => snapshot.resources,
      KeeneticMetricKind.interfaces => snapshot.interfaces,
    };
    final instant = now ?? DateTime.now();
    final internetAge = snapshot.internet.readAt == null
        ? null
        : instant.difference(snapshot.internet.readAt!);
    final currentWan =
        request.interfaceId != null &&
        snapshot.internet.succeeded &&
        snapshot.internet.value?.gatewayInterfaceId == request.interfaceId &&
        internetAge != null &&
        internetAge >= Duration.zero &&
        internetAge <= const Duration(seconds: 45);
    final gateway = snapshot.interfaces.value
        ?.where(
          (item) => item.id == snapshot.internet.value?.gatewayInterfaceId,
        )
        .firstOrNull;
    final lines = switch (request.kind) {
      KeeneticMetricKind.internetStatus => <KeeneticMetricLine>[
        (
          label: l10n.keeneticInternetStatus,
          value: flag(snapshot.internet.value?.internet),
        ),
        (label: l10n.keeneticInterfaceAddress, value: text(gateway?.address)),
        (
          label: l10n.keeneticGateway,
          value: text(snapshot.internet.value?.gatewayAddress),
        ),
        (
          label: l10n.keeneticDnsCheck,
          value: flag(snapshot.internet.value?.dnsAccessible),
        ),
        (
          label: l10n.keeneticHostCheck,
          value: flag(snapshot.internet.value?.hostAccessible),
        ),
      ],
      KeeneticMetricKind.wanTraffic => <KeeneticMetricLine>[
        (
          label: currentWan
              ? l10n.keeneticDownloadRate
              : l10n.keeneticReceiveRate,
          value: formatKeeneticRate(
            traffic?.value?.receiveBytesPerSecond,
            l10n,
          ),
        ),
        (
          label: currentWan ? l10n.keeneticUploadRate : l10n.keeneticSendRate,
          value: formatKeeneticRate(traffic?.value?.sendBytesPerSecond, l10n),
        ),
        (label: l10n.keeneticInterfaceAddress, value: text(selected?.address)),
        (label: l10n.keeneticInterface, value: text(request.interfaceId)),
        (
          label: l10n.keeneticReceivedTotal,
          value: _bytes(traffic?.value?.receivedBytes, l10n),
        ),
        (
          label: l10n.keeneticSentTotal,
          value: _bytes(traffic?.value?.sentBytes, l10n),
        ),
      ],
      KeeneticMetricKind.connectedDevices => <KeeneticMetricLine>[
        (
          label: l10n.keeneticConnectedDevices,
          value: text(snapshot.hosts.value?.activeHosts),
        ),
        (
          label: l10n.keeneticKnownDevices,
          value: text(snapshot.hosts.value?.knownHosts),
        ),
        (
          label: l10n.keeneticUnmeasuredDevices,
          value: text(snapshot.hosts.value?.unknownActivityHosts),
        ),
      ],
      KeeneticMetricKind.routerResources => <KeeneticMetricLine>[
        (
          label: l10n.keeneticCpuUsage,
          value: percent(snapshot.resources.value?.cpuPercent),
        ),
        (
          label: l10n.keeneticMemoryUsage,
          value: percent(snapshot.resources.value?.memoryPercent),
        ),
        (
          label: l10n.keeneticUptime,
          value: _uptime(snapshot.resources.value?.uptimeSeconds, l10n),
        ),
        (
          label: l10n.keeneticFirmware,
          value: text(snapshot.resources.value?.firmware),
        ),
      ],
      KeeneticMetricKind.interfaces => <KeeneticMetricLine>[
        for (final item in snapshot.interfaces.value ?? <KeeneticInterface>[])
          (
            label: item.description ?? item.id,
            value: '${flag(item.connected)} · ${text(item.address)}',
          ),
      ],
    };
    final secondaryIssue = switch (request.kind) {
      KeeneticMetricKind.internetStatus ||
      KeeneticMetricKind.wanTraffic => snapshot.interfaces.issue,
      _ => null,
    };
    final issue = reading.issue ?? snapshot.connectionIssue ?? secondaryIssue;
    return KeeneticMetricPresentation(
      lines: List.unmodifiable(lines),
      issue: issue,
      readAt: reading.readAt,
      stale: reading.value != null && issue != null,
      awaitingSample:
          request.kind == KeeneticMetricKind.wanTraffic &&
          traffic?.value != null &&
          traffic?.issue == null &&
          traffic!.value!.receiveBytesPerSecond == null &&
          traffic.value!.sendBytesPerSecond == null,
    );
  }
}
