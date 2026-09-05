class EntityHistoryPoint {
  const EntityHistoryPoint(this.time, this.value);
  final DateTime time;
  final double? value;
}

class EntityHistorySeries {
  const EntityHistorySeries({required this.points, required this.readAt});
  final List<EntityHistoryPoint> points;
  final DateTime readAt;
  bool get hasValues => points.any((point) => point.value != null);
}

/// Unknown states are gaps, not zero. Never send NaN/Infinity to the chart.
EntityHistorySeries parseEntityHistory(
  List<List<Map<String, dynamic>>> result, {
  required String entityId,
  required DateTime start,
  required DateTime end,
}) {
  if (result.length > 1 || (result.firstOrNull?.length ?? 0) > 10000) {
    throw const FormatException('Invalid history response');
  }
  final values = <DateTime, double?>{};
  for (final entry in result.firstOrNull ?? <Map<String, dynamic>>[]) {
    if (entry['entity_id'] != null && entry['entity_id'] != entityId) {
      throw const FormatException('Unexpected history entity');
    }
    final timestamp = entry['last_updated'] ?? entry['last_changed'];
    if (timestamp is! String ||
        !RegExp(
          r'(Z|[+-]\d{2}:?\d{2})$',
          caseSensitive: false,
        ).hasMatch(timestamp)) {
      throw const FormatException('Invalid history timestamp');
    }
    final parsed = DateTime.tryParse(timestamp)?.toUtc();
    if (parsed == null || parsed.isAfter(end)) {
      throw const FormatException('Invalid history timestamp');
    }
    // HA may include the state in effect at the requested start.
    final time = parsed.isBefore(start) ? start : parsed;
    final raw = entry['state'];
    final value = raw is num
        ? raw.toDouble()
        : raw is String
        ? double.tryParse(raw)
        : null;
    values[time] = value != null && value.isFinite ? value : null;
  }
  final times = values.keys.toList()..sort();
  return EntityHistorySeries(
    points: List.unmodifiable(
      times.map((time) => EntityHistoryPoint(time, values[time])),
    ),
    readAt: end,
  );
}
