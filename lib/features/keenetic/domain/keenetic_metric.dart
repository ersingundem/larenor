/// Stable persisted choices; interface selectors remain separate opaque IDs.
enum KeeneticMetricKind {
  internetStatus,
  wanTraffic,
  connectedDevices,
  routerResources,
  interfaces,
  // Appended so persisted enum names and generated serialization stay stable.
  connectionQuality,
}

bool keeneticMetricNeedsInterface(KeeneticMetricKind kind) =>
    kind == KeeneticMetricKind.wanTraffic ||
    kind == KeeneticMetricKind.connectionQuality;

bool keeneticMetricNeedsTraffic(KeeneticMetricKind kind) =>
    keeneticMetricNeedsInterface(kind);

class KeeneticMetricRequest {
  const KeeneticMetricRequest(this.kind, {this.interfaceId});
  final KeeneticMetricKind kind;
  final String? interfaceId;

  @override
  bool operator ==(Object other) =>
      other is KeeneticMetricRequest &&
      other.kind == kind &&
      other.interfaceId == interfaceId;
  @override
  int get hashCode => Object.hash(kind, interfaceId);
}
