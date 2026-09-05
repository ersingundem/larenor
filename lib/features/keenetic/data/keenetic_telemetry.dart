import '../domain/keenetic_metric.dart';
import 'models/keenetic_router_status.dart';

export '../domain/keenetic_metric.dart';

enum KeeneticReadFailure {
  authentication,
  permission,
  transport,
  timeout,
  unsupported,
  invalidResponse,
  server,
  rejected,
  inactive,
  selectionRequired,
}

enum KeeneticCapabilityState { unknown, supported, unsupported, denied }

class KeeneticReading<T> {
  const KeeneticReading({this.value, this.readAt, this.issue});
  final T? value;
  final DateTime? readAt;
  final KeeneticReadFailure? issue;
  bool get isStale => value != null && issue != null;
  bool get succeeded => value != null && issue == null;

  KeeneticReading<T> retaining(KeeneticReading<T> previous) =>
      value != null || issue == null
      ? this
      : KeeneticReading(
          value: previous.value,
          readAt: previous.readAt,
          issue: issue,
        );
}

class KeeneticTelemetryDemand {
  KeeneticTelemetryDemand({
    Iterable<KeeneticMetricKind> kinds = const [],
    Iterable<String> interfaceIds = const [],
  }) : kinds = Set.unmodifiable(kinds),
       interfaceIds = Set.unmodifiable(interfaceIds);
  final Set<KeeneticMetricKind> kinds;
  final Set<String> interfaceIds;
  bool get isEmpty => kinds.isEmpty;
}

class KeeneticInternetStatus {
  const KeeneticInternetStatus({
    this.internet,
    this.gatewayAccessible,
    this.dnsAccessible,
    this.hostAccessible,
    this.reliable,
    this.checkedAt,
    this.gatewayInterfaceId,
    this.gatewayAddress,
  });
  final bool? internet,
      gatewayAccessible,
      dnsAccessible,
      hostAccessible,
      reliable;

  /// Router-provided timestamp/string; independent from the local readAt.
  final String? checkedAt;
  final String? gatewayInterfaceId, gatewayAddress;
  factory KeeneticInternetStatus.fromJson(Map<String, dynamic> json) {
    final gateway = json['gateway'];
    return KeeneticInternetStatus(
      internet: keeneticFlag(json['internet']),
      gatewayAccessible: keeneticFlag(json['gateway-accessible']),
      dnsAccessible: keeneticFlag(json['dns-accessible']),
      hostAccessible: keeneticFlag(json['host-accessible']),
      reliable: keeneticFlag(json['reliable']),
      checkedAt: keeneticText(json['checked']),
      gatewayInterfaceId: gateway is Map
          ? keeneticText(gateway['interface'])
          : null,
      gatewayAddress: gateway is Map ? keeneticText(gateway['address']) : null,
    );
  }
  bool get hasEvidence =>
      internet != null ||
      gatewayAccessible != null ||
      dnsAccessible != null ||
      hostAccessible != null;
}

class KeeneticInterface {
  KeeneticInterface({
    required this.id,
    this.description,
    this.type,
    this.adminUp,
    this.linkUp,
    this.connected,
    this.address,
    this.mask,
    this.parentId,
    Iterable<String> memberIds = const [],
  }) : memberIds = List.unmodifiable(memberIds);
  final String id;
  final String? description, type, address, mask, parentId;
  final bool? adminUp, linkUp, connected;
  final List<String> memberIds;
  factory KeeneticInterface.fromJson(Map<String, dynamic> json) {
    final id = keeneticText(json['id']);
    if (id == null ||
        id.length > 256 ||
        id.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw const FormatException('Invalid interface identity.');
    }
    final members = json['bridge'];
    return KeeneticInterface(
      id: id,
      description: keeneticText(json['description']),
      type: keeneticText(json['type']),
      adminUp: keeneticFlag(json['state']),
      linkUp: keeneticFlag(json['link']),
      connected: keeneticFlag(json['connected']),
      address: keeneticText(json['address']),
      mask: keeneticText(json['mask']),
      parentId: keeneticText(json['parent']),
      memberIds: members is Map && members['interface'] is List
          ? (members['interface'] as List).map(keeneticText).whereType<String>()
          : const [],
    );
  }
}

class KeeneticHostSummary {
  KeeneticHostSummary({
    required this.knownHosts,
    required this.unknownActivityHosts,
    required this.activeHosts,
    Map<String, int> activeByInterface = const {},
  }) : activeByInterface = Map.unmodifiable(activeByInterface);
  final int knownHosts, unknownActivityHosts;
  final int? activeHosts;
  final Map<String, int> activeByInterface;
  factory KeeneticHostSummary.fromJson(List<Map<String, dynamic>> rows) {
    final seen = <String>{};
    final activeByInterface = <String, int>{};
    var active = 0;
    var unknown = 0;
    for (final row in rows) {
      final mac = keeneticText(row['mac'])?.toLowerCase();
      if (mac == null || !seen.add(mac)) {
        throw const FormatException('Invalid or duplicate host identity.');
      }
      final online = keeneticFlag(row['active']);
      if (online == null) unknown++;
      if (online == true) {
        active++;
        final id = keeneticText(row['via']);
        if (id != null) {
          activeByInterface.update(id, (n) => n + 1, ifAbsent: () => 1);
        }
      }
    }
    return KeeneticHostSummary(
      knownHosts: seen.length,
      unknownActivityHosts: unknown,
      activeHosts: unknown == 0 ? active : null,
      activeByInterface: unknown == 0 ? activeByInterface : const {},
    );
  }
}

class KeeneticTrafficSample {
  const KeeneticTrafficSample({
    required this.interfaceId,
    this.receivedBytes,
    this.sentBytes,
    this.routerTimestamp,
    this.receiveBytesPerSecond,
    this.sendBytesPerSecond,
    this.interval,
  });
  final String interfaceId;
  final int? receivedBytes, sentBytes;
  final num? routerTimestamp;
  final double? receiveBytesPerSecond, sendBytesPerSecond;
  final Duration? interval;
  factory KeeneticTrafficSample.fromJson(
    String id,
    Map<String, dynamic> json,
  ) => KeeneticTrafficSample(
    interfaceId: id,
    receivedBytes: keeneticCounter(json['rxbytes']),
    sentBytes: keeneticCounter(json['txbytes']),
    routerTimestamp:
        json['timestamp'] is num && (json['timestamp'] as num).isFinite
        ? json['timestamp'] as num
        : null,
  );
}

/// Monotonic interval averages, never interface link capacity. Each controller
/// owns a sampler; no baseline is persisted or shared across accounts.
class KeeneticTrafficSampler {
  final _previous = <String, (KeeneticTrafficSample, Duration, int?)>{};
  void reset() => _previous.clear();
  KeeneticTrafficSample add(
    KeeneticTrafficSample current,
    Duration tick, {
    int? uptimeSeconds,
  }) {
    final previous = _previous[current.interfaceId];
    _previous[current.interfaceId] = (
      current,
      tick,
      uptimeSeconds ?? previous?.$3,
    );
    if (previous == null) return current;
    final (before, beforeTick, beforeUptime) = previous;
    final elapsed = tick - beforeTick;
    final reboot =
        uptimeSeconds != null &&
        beforeUptime != null &&
        uptimeSeconds < beforeUptime;
    final duplicate =
        current.routerTimestamp != null &&
        before.routerTimestamp != null &&
        current.routerTimestamp! <= before.routerTimestamp!;
    if (elapsed <= Duration.zero ||
        elapsed > const Duration(seconds: 20) ||
        reboot ||
        duplicate) {
      return current;
    }
    double? rate(int? end, int? start) =>
        end == null || start == null || end < start
        ? null
        : (end - start) /
              (elapsed.inMicroseconds / Duration.microsecondsPerSecond);
    return KeeneticTrafficSample(
      interfaceId: current.interfaceId,
      receivedBytes: current.receivedBytes,
      sentBytes: current.sentBytes,
      routerTimestamp: current.routerTimestamp,
      receiveBytesPerSecond: rate(current.receivedBytes, before.receivedBytes),
      sendBytesPerSecond: rate(current.sentBytes, before.sentBytes),
      interval: elapsed,
    );
  }
}

class KeeneticTelemetrySnapshot {
  KeeneticTelemetrySnapshot({
    required this.accountGeneration,
    this.resources = const KeeneticReading(),
    this.internet = const KeeneticReading(),
    this.interfaces = const KeeneticReading(),
    this.hosts = const KeeneticReading(),
    Map<String, KeeneticReading<KeeneticTrafficSample>> traffic = const {},
    this.connectionIssue,
    this.isRefreshing = false,
    this.isPaused = false,
  }) : traffic = Map.unmodifiable(traffic);
  final Object accountGeneration;
  final KeeneticReading<KeeneticRouterStatus> resources;
  final KeeneticReading<KeeneticInternetStatus> internet;
  final KeeneticReading<List<KeeneticInterface>> interfaces;
  final KeeneticReading<KeeneticHostSummary> hosts;
  final Map<String, KeeneticReading<KeeneticTrafficSample>> traffic;
  final KeeneticReadFailure? connectionIssue;
  final bool isRefreshing, isPaused;
  KeeneticCapabilityState capability(KeeneticMetricKind kind) {
    if (kind == KeeneticMetricKind.wanTraffic) {
      if (traffic.values.any(
        (reading) => reading.issue == KeeneticReadFailure.permission,
      )) {
        return KeeneticCapabilityState.denied;
      }
      if (traffic.values.any((reading) => reading.succeeded)) {
        return KeeneticCapabilityState.supported;
      }
      if (traffic.isNotEmpty &&
          traffic.values.every(
            (reading) => reading.issue == KeeneticReadFailure.unsupported,
          )) {
        return KeeneticCapabilityState.unsupported;
      }
      return KeeneticCapabilityState.unknown;
    }
    final reading = switch (kind) {
      KeeneticMetricKind.routerResources => resources,
      KeeneticMetricKind.internetStatus => internet,
      KeeneticMetricKind.interfaces => interfaces,
      KeeneticMetricKind.connectedDevices => hosts,
      KeeneticMetricKind.wanTraffic => interfaces,
    };
    return switch (reading.issue) {
      KeeneticReadFailure.unsupported => KeeneticCapabilityState.unsupported,
      KeeneticReadFailure.permission => KeeneticCapabilityState.denied,
      _ =>
        reading.value != null
            ? KeeneticCapabilityState.supported
            : KeeneticCapabilityState.unknown,
    };
  }
}

bool? keeneticFlag(Object? value) => switch (value) {
  true || 1 || 'yes' || 'up' || 'connected' => true,
  false || 0 || 'no' || 'down' || 'disconnected' => false,
  _ => null,
};
String? keeneticText(Object? value) =>
    value is String && value.trim().isNotEmpty && value.length <= 1024
    ? value.trim()
    : null;
int? keeneticCounter(Object? value) {
  // Values beyond exact JSON integer precision are deliberately unknown.
  final number = value is int
      ? value
      : value is String
      ? int.tryParse(value)
      : null;
  return number != null && number >= 0 && number <= 9007199254740991
      ? number
      : null;
}
