import '../../ha_client/data/rest_client.dart';
import '../../ha_client/data/ws_client.dart';
import '../domain/energy_models.dart';
import 'energy_configuration.dart';

/// An intentionally read-only API: there is no service-call or preference-save method.
abstract interface class EnergyApi {
  Future<Map<String, dynamic>> getConfig();
  Future<Object?> getPreferences();
  Future<Object?> getInformation();
  Future<Object?> getMetadata(List<String> statisticIds);
  Future<Object?> getStatistics({
    required List<String> statisticIds,
    required DateTime start,
    required DateTime endInclusive,
    required bool hourly,
  });
}

class HaEnergyApi implements EnergyApi {
  HaEnergyApi({required this.rest, required this.ws});
  final HaRestClient rest;
  final HaWebSocketClient ws;
  @override
  Future<Map<String, dynamic>> getConfig() => rest.getConfig();
  @override
  Future<Object?> getPreferences() =>
      ws.sendCommand({'type': 'energy/get_prefs'});
  @override
  Future<Object?> getInformation() => ws.sendCommand({'type': 'energy/info'});
  void _ids(List<String> ids) {
    if (ids.isEmpty ||
        ids.length > energyStatisticLimit ||
        ids.toSet().length != ids.length) {
      throw const EnergyException(EnergyFailure.limitExceeded);
    }
    for (final id in ids) {
      energyStatisticId(id);
    }
  }

  @override
  Future<Object?> getMetadata(List<String> statisticIds) {
    _ids(statisticIds);
    return ws.sendCommand({
      'type': 'recorder/get_statistics_metadata',
      'statistic_ids': List<String>.of(statisticIds),
    });
  }

  @override
  Future<Object?> getStatistics({
    required List<String> statisticIds,
    required DateTime start,
    required DateTime endInclusive,
    required bool hourly,
  }) {
    _ids(statisticIds);
    if (!endInclusive.isAfter(start) ||
        endInclusive.difference(start) > const Duration(days: 9)) {
      throw const EnergyException(EnergyFailure.invalidResponse);
    }
    return ws.sendCommand({
      'type': 'recorder/statistics_during_period',
      'statistic_ids': List<String>.of(statisticIds),
      'start_time': start.toUtc().toIso8601String(),
      'end_time': endInclusive.toUtc().toIso8601String(),
      'period': hourly ? 'hour' : 'day',
      'units': {'energy': 'kWh'},
      'types': ['change'],
    });
  }
}
