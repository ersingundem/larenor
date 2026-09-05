import '../../keenetic/domain/keenetic_metric.dart';

/// Shared local/portable-backup rules. Interface IDs are opaque JSON selectors,
/// never URL paths, shell commands or HA entity IDs.
bool hasValidKeeneticTileFields(Map<String, dynamic> tile) {
  final metric = tile['keeneticMetric'];
  final id = tile['keeneticInterfaceId'];
  if (metric == null) return id == null;
  if (tile['type'] != 'keenetic' ||
      tile['entityId'] != null ||
      tile['url'] != null ||
      !KeeneticMetricKind.values.any((kind) => kind.name == metric)) {
    return false;
  }
  if (metric != KeeneticMetricKind.wanTraffic.name) return id == null;
  return id is String &&
      id.isNotEmpty &&
      id.length <= 256 &&
      id.trim() == id &&
      !id.contains(RegExp(r'[\x00-\x1f\x7f]'));
}
