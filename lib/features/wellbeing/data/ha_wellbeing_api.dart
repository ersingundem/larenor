import '../../ha_client/data/ha_api_exception.dart';
import '../../ha_client/data/models/ha_entity.dart';
import '../../ha_client/data/rest_client.dart';
import '../domain/wellbeing_models.dart';
import 'wellbeing_store.dart';

abstract interface class HaWellbeingApi {
  String get accountFingerprint;
  Future<List<HaWellbeingCandidate>> candidates({bool Function()? isCurrent});
  Future<List<WellbeingReadResult>> read(
    List<HaWellbeingBinding> bindings, {
    bool Function()? isCurrent,
  });
}

class RestHaWellbeingApi implements HaWellbeingApi {
  RestHaWellbeingApi({
    required this.client,
    required this.accountFingerprint,
    required this.isCurrent,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final HaRestClient client;
  @override
  final String accountFingerprint;
  final bool Function() isCurrent;
  final DateTime Function() _now;
  void _check([bool Function()? operationCurrent]) {
    if (!isCurrent() || operationCurrent?.call() == false) {
      throw const WellbeingException(WellbeingFailure.accountChanged);
    }
  }

  @override
  Future<List<HaWellbeingCandidate>> candidates({
    bool Function()? isCurrent,
  }) async {
    _check(isCurrent);
    try {
      final states = await client.getStates();
      _check(isCurrent);
      return List.unmodifiable([
        for (final entity in states.take(20000))
          if (validWellbeingEntityId(entity.entityId) &&
              _metrics(entity).isNotEmpty)
            HaWellbeingCandidate(
              entityId: entity.entityId,
              name: _safeName(entity.friendlyName, entity.entityId),
              unit: entity.attributes['unit_of_measurement'] as String,
              accountFingerprint: accountFingerprint,
              compatibleMetrics: _metrics(entity),
            ),
      ]);
    } on WellbeingException {
      rethrow;
    } catch (error) {
      throw WellbeingException(_failure(error));
    }
  }

  static const massUnits = <String, double>{
    'kg': 1,
    'g': 0.001,
    'mg': 0.000001,
    'µg': 0.000000001,
    'oz': 0.028349523125,
    'lb': 0.45359237,
    'st': 6.35029318,
  };
  static Set<WellbeingMetric> _metrics(HaEntity entity) {
    final unit = entity.attributes['unit_of_measurement'];
    return {
      if (massUnits.containsKey(unit)) WellbeingMetric.bodyMass,
      if (unit == '%') WellbeingMetric.bodyFatPercentage,
    };
  }

  @override
  Future<List<WellbeingReadResult>> read(
    List<HaWellbeingBinding> bindings, {
    bool Function()? isCurrent,
  }) async {
    _check(isCurrent);
    if (bindings.length > 32) {
      throw const WellbeingException(WellbeingFailure.invalidData);
    }
    final results = <WellbeingReadResult>[];
    for (final binding in bindings) {
      _check(isCurrent);
      if (binding.accountFingerprint != accountFingerprint) {
        results.add(_failed(binding.metric, WellbeingFailure.accountChanged));
        continue;
      }
      if (!validWellbeingEntityId(binding.entityId) ||
          binding.metric == WellbeingMetric.steps) {
        results.add(_failed(binding.metric, WellbeingFailure.invalidData));
        continue;
      }
      try {
        final entity = await client.getState(binding.entityId);
        _check(isCurrent);
        if (entity.entityId != binding.entityId) {
          throw const WellbeingException(WellbeingFailure.sourceChanged);
        }
        results.add(mapEntity(entity, binding, _now()));
      } on WellbeingException {
        rethrow;
      } catch (error) {
        _check(isCurrent);
        results.add(_failed(binding.metric, _failure(error)));
      }
    }
    return List.unmodifiable(results);
  }

  static WellbeingReadResult mapEntity(
    HaEntity entity,
    HaWellbeingBinding binding,
    DateTime readAt,
  ) {
    if (entity.state == 'unknown' || entity.state == 'unavailable') {
      return _failed(binding.metric, WellbeingFailure.unavailable);
    }
    final unit = entity.attributes['unit_of_measurement'];
    final original = double.tryParse(entity.state);
    if (!_metrics(entity).contains(binding.metric) ||
        original == null ||
        !original.isFinite) {
      return _failed(binding.metric, WellbeingFailure.invalidData);
    }
    final value = binding.metric == WellbeingMetric.bodyMass
        ? original * massUnits[unit]!
        : original;
    if (!value.isFinite ||
        value < 0 ||
        (binding.metric == WellbeingMetric.bodyFatPercentage && value > 100)) {
      return _failed(binding.metric, WellbeingFailure.invalidData);
    }
    return WellbeingReadResult(
      source: WellbeingSource.homeAssistant,
      metric: binding.metric,
      state: WellbeingReadState.data,
      readAt: readAt,
      measurements: [
        WellbeingMeasurement(
          source: WellbeingSource.homeAssistant,
          metric: binding.metric,
          value: value,
          unit: binding.metric == WellbeingMetric.bodyMass ? 'kg' : '%',
          profileLabel: binding.profileLabel,
          readAt: readAt,
          originalValue: original,
          originalUnit: unit as String,
          // HA state updates are not proof of a new physical measurement.
          sourceUpdatedAt: entity.lastUpdated,
          originName: _safeName(entity.friendlyName, 'Home Assistant'),
        ),
      ],
    );
  }

  static WellbeingReadResult _failed(
    WellbeingMetric metric,
    WellbeingFailure failure,
  ) => WellbeingReadResult(
    source: WellbeingSource.homeAssistant,
    metric: metric,
    state: WellbeingReadState.failed,
    failure: failure,
  );
  static WellbeingFailure _failure(Object error) =>
      error is HaApiException &&
          (error.statusCode == 401 || error.statusCode == 403)
      ? WellbeingFailure.permission
      : WellbeingFailure.readFailed;
  static String _safeName(String value, String fallback) =>
      value.length <= 160 && !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)
      ? value
      : fallback;
}
