import '../../domain/server_models.dart';

Map<String, dynamic> _closed(Object? value, Set<String> keys) {
  final json = serverObject(value);
  if (json.length != keys.length || !json.keys.every(keys.contains)) {
    throw const LarenorServerException('invalid_response');
  }
  return json;
}

final class HabitAnomalyCurrent {
  const HabitAnomalyCurrent({
    required this.observationId,
    required this.value,
    required this.observedAtMs,
    required this.feedback,
  });

  factory HabitAnomalyCurrent.fromJson(Object? value) {
    final json = _closed(value, const {
      'observationId',
      'value',
      'observedAtMs',
      'feedback',
    });
    final id = json['observationId'];
    final metricValue = json['value'];
    final observedAtMs = json['observedAtMs'];
    final feedback = json['feedback'];
    if (id is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(id) ||
        metricValue is! num ||
        !metricValue.isFinite ||
        observedAtMs is! int ||
        observedAtMs < 0 ||
        (feedback != null &&
            feedback != 'normal' &&
            feedback != 'false_positive')) {
      throw const LarenorServerException('invalid_response');
    }
    return HabitAnomalyCurrent(
      observationId: id,
      value: metricValue.toDouble(),
      observedAtMs: observedAtMs,
      feedback: feedback as String?,
    );
  }

  final String observationId;
  final double value;
  final int observedAtMs;
  final String? feedback;
}

final class HabitAnomalyBaseline {
  const HabitAnomalyBaseline({
    required this.sampleCount,
    required this.center,
    required this.tolerance,
  });

  factory HabitAnomalyBaseline.fromJson(Object? value) {
    final json = _closed(value, const {'sampleCount', 'center', 'tolerance'});
    final count = json['sampleCount'];
    final center = json['center'];
    final tolerance = json['tolerance'];
    if (count is! int ||
        count < 1 ||
        center is! num ||
        tolerance is! num ||
        !center.isFinite ||
        !tolerance.isFinite ||
        tolerance < 0) {
      throw const LarenorServerException('invalid_response');
    }
    return HabitAnomalyBaseline(
      sampleCount: count,
      center: center.toDouble(),
      tolerance: tolerance.toDouble(),
    );
  }

  final int sampleCount;
  final double center, tolerance;
}

final class HabitAnomalyReport {
  const HabitAnomalyReport({
    required this.seriesId,
    required this.metric,
    required this.unit,
    required this.modelVersion,
    required this.classification,
    required this.unknownReason,
    required this.sampleCount,
    required this.minimumBaselineSamples,
    required this.current,
    required this.baseline,
  });

  factory HabitAnomalyReport.fromJson(Object? value) {
    final json = _closed(value, const {
      'schemaVersion',
      'seriesId',
      'metric',
      'unit',
      'modelVersion',
      'classification',
      'unknownReason',
      'sampleCount',
      'minimumBaselineSamples',
      'current',
      'baseline',
      'missingDataIsUnknown',
    });
    final classification = json['classification'];
    final reason = json['unknownReason'];
    final sampleCount = json['sampleCount'];
    final minimum = json['minimumBaselineSamples'];
    if (json['schemaVersion'] != 1 ||
        !{'unknown', 'normal', 'anomaly'}.contains(classification) ||
        (reason != null &&
            !{
              'stale_data',
              'insufficient_samples',
              'insufficient_span',
            }.contains(reason)) ||
        (classification == 'unknown') != (reason != null) ||
        sampleCount is! int ||
        sampleCount < 1 ||
        minimum is! int ||
        minimum < 1 ||
        json['missingDataIsUnknown'] != true) {
      throw const LarenorServerException('invalid_response');
    }
    return HabitAnomalyReport(
      seriesId: serverText(json['seriesId'], max: 64),
      metric: serverText(json['metric'], max: 64),
      unit: serverText(json['unit'], max: 32),
      modelVersion: serverText(json['modelVersion'], max: 64),
      classification: classification as String,
      unknownReason: reason as String?,
      sampleCount: sampleCount,
      minimumBaselineSamples: minimum,
      current: HabitAnomalyCurrent.fromJson(json['current']),
      baseline: json['baseline'] == null
          ? null
          : HabitAnomalyBaseline.fromJson(json['baseline']),
    );
  }

  final String seriesId, metric, unit, modelVersion, classification;
  final String? unknownReason;
  final int sampleCount, minimumBaselineSamples;
  final HabitAnomalyCurrent current;
  final HabitAnomalyBaseline? baseline;
}
