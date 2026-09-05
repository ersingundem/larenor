/// Stable persisted choices; interface selectors remain separate opaque IDs.
enum KeeneticMetricKind {
  internetStatus,
  wanTraffic,
  connectedDevices,
  routerResources,
  interfaces,
}

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
