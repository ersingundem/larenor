import '../../home_resources/domain/home_resource_models.dart';
import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../../server/services/domain/server_service_models.dart';
import '../domain/irrigation_source_models.dart';

final class CoreIrrigationSourceApi {
  CoreIrrigationSourceApi({required this.account, required this.isCurrent});
  final ServerAccountController account;
  final bool Function() isCurrent;
  ServerSession? _session;
  bool _retired = false;

  void retire() {
    _retired = true;
    _session = null;
  }

  void _check(ServerSession session) {
    var current = false;
    try {
      current = !_retired && isCurrent();
    } catch (_) {
      current = false;
    }
    if (!current || !identical(account.session, session)) {
      retire();
      throw const LarenorServerException('cancelled');
    }
    _session ??= session;
    if (!identical(_session, session) ||
        !session.user.canAdminister ||
        session.context == null) {
      retire();
      throw const LarenorServerException('forbidden');
    }
  }

  Future<IrrigationSetupCatalog> load() => account.withSession((
    api,
    session,
  ) async {
    _check(session);
    final context = session.context!;
    final servicesRaw = _object(
      await api.request('GET', '/admin/services', token: session.accessToken),
    );
    final rooms = await _loadRooms(api, session, context);
    Map<String, dynamic>? sourceRaw;
    Map<String, dynamic>? controllerRaw;
    try {
      sourceRaw = _object(
        await api.request(
          'GET',
          '/admin/irrigation-budget/source',
          token: session.accessToken,
        ),
      );
    } on LarenorServerException catch (error) {
      if (error.code != 'irrigation_source_not_configured' &&
          error.code != 'conflict') {
        rethrow;
      }
    }
    try {
      controllerRaw = _object(
        await api.request(
          'GET',
          '/admin/irrigation-budget/controller',
          token: session.accessToken,
        ),
      );
    } on LarenorServerException catch (error) {
      if (error.code != 'irrigation_controller_not_configured' &&
          error.code != 'conflict') {
        rethrow;
      }
    }
    _check(session);
    return IrrigationSetupCatalog(
      services: _services(servicesRaw),
      rooms: rooms,
      source: sourceRaw == null ? null : _source(sourceRaw),
      controller: controllerRaw == null ? null : _controller(controllerRaw),
    );
  });

  Future<IrrigationSourceSettings> saveSource(Map<String, dynamic> body) =>
      account.withSession((api, session) async {
        _check(session);
        final response = _object(
          await api.request(
            'PUT',
            '/admin/irrigation-budget/source',
            token: session.accessToken,
            body: body,
          ),
        );
        _check(session);
        return _source(response);
      });

  Future<IrrigationControllerSettings> saveController(
    Map<String, dynamic> body,
  ) => account.withSession((api, session) async {
    _check(session);
    final response = _object(
      await api.request(
        'PUT',
        '/admin/irrigation-budget/controller',
        token: session.accessToken,
        body: body,
      ),
    );
    _check(session);
    return _controller(response);
  });

  Future<List<IrrigationRoomOption>> _loadRooms(
    LarenorServerApi api,
    ServerSession session,
    ServerContext context,
  ) async {
    final rooms = <IrrigationRoomOption>[];
    final seen = <String>{};
    String? after, snapshot;
    for (var pageIndex = 0; pageIndex < 6; pageIndex++) {
      final page = HomeResourcePage.fromJson(
        await api.request(
          'GET',
          '/home-resources/${context.coreId}/${context.homeId}',
          token: session.accessToken,
          queryParameters: {
            'limit': '100',
            'after': ?after,
            'expectedSnapshot': ?snapshot,
          },
        ),
        expectedContext: context,
        expectedSnapshot: snapshot,
        after: after,
        limit: 100,
      );
      for (final value in page.entries) {
        if (!seen.add(value.id)) _invalid();
        if (value.kind == HomeResourceKind.room) {
          rooms.add(
            IrrigationRoomOption(
              id: value.id,
              revision: value.revision,
              label: value.label,
            ),
          );
        }
      }
      if (seen.length > HomeResourcePage.maximumRecords) _invalid();
      snapshot = page.snapshot;
      after = page.nextAfter;
      if (after == null) return List.unmodifiable(rooms);
    }
    _invalid();
  }
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map<String, dynamic>) _invalid();
  return value;
}

Never _invalid() => throw const LarenorServerException('invalid_response');

void _keys(Map<String, dynamic> value, Set<String> keys) {
  if (value.length != keys.length || !value.keys.toSet().containsAll(keys)) {
    _invalid();
  }
}

String _id(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

String _text(Object? value, int max) {
  if (value is! String ||
      value.isEmpty ||
      value.length > max ||
      value.trim() != value) {
    _invalid();
  }
  return value;
}

int _integer(Object? value, int minimum, int maximum) {
  if (value is! int || value < minimum || value > maximum) _invalid();
  return value;
}

List<IrrigationServiceOption> _services(Map<String, dynamic> raw) {
  _keys(raw, const {'services'});
  final values = raw['services'];
  if (values is! List || values.length > 128) _invalid();
  final services = <IrrigationServiceOption>[];
  for (final item in values) {
    final service = ServerService.fromJson(_object(item));
    if (service.kind == ServerServiceKind.homeAssistant) {
      services.add(
        IrrigationServiceOption(
          id: service.id,
          revision: service.revision,
          name: service.name,
        ),
      );
    }
  }
  return List.unmodifiable(services);
}

IrrigationSourceSettings _source(Map<String, dynamic> response) {
  _keys(response, const {'schemaVersion', 'source', 'controlZones'});
  if (response['schemaVersion'] != 1) _invalid();
  final raw = _object(response['source']);
  final controlsRaw = response['controlZones'];
  _keys(raw, const {
    'schemaVersion',
    'revision',
    'serviceId',
    'serviceRevision',
    'weatherEntityId',
    'leakEntityId',
    'dailyWaterEntityId',
    'targetMoisturePermille',
    'soilMaxAgeMs',
    'safetyMaxAgeMs',
    'forecastMaxAgeMs',
    'rainDeferralMilliMm',
    'freezeThresholdMilliC',
    'windLimitMilliMps',
    'previewTtlMs',
    'dailyLimitMl',
    'priceMicrosPerLiter',
    'zones',
  });
  final zonesRaw = raw['zones'];
  if (raw['schemaVersion'] != 1 ||
      zonesRaw is! List ||
      controlsRaw is! List ||
      zonesRaw.isEmpty ||
      zonesRaw.length > 32) {
    _invalid();
  }
  if (controlsRaw.length != zonesRaw.length) _invalid();
  final controls = <String, Map<String, dynamic>>{};
  for (final item in controlsRaw) {
    final control = _object(item);
    _keys(control, const {'zoneId', 'zoneRevision', 'valveEntityId'});
    final valve = _text(control['valveEntityId'], 128);
    if (controls.containsKey(valve)) _invalid();
    controls[valve] = control;
  }
  final zones = zonesRaw
      .map((item) {
        final zone = _object(item);
        _keys(zone, const {
          'roomId',
          'roomRevision',
          'valveEntityId',
          'soilMoistureEntityId',
          'plantName',
          'flowMlPerMinute',
          'maxDurationSeconds',
        });
        final valve = _text(zone['valveEntityId'], 128);
        final control = controls[valve];
        if (control == null) _invalid();
        return IrrigationZoneSourceSettings(
          roomId: _id(zone['roomId']),
          roomRevision: _integer(zone['roomRevision'], 1, 0x7fffffffffffffff),
          valveEntityId: valve,
          soilMoistureEntityId: _text(zone['soilMoistureEntityId'], 128),
          plantName: _text(zone['plantName'], 120),
          flowMlPerMinute: _integer(zone['flowMlPerMinute'], 1, 1000000),
          maxDurationSeconds: _integer(zone['maxDurationSeconds'], 1, 7200),
          zoneId: _id(control['zoneId']),
          zoneRevision: _integer(
            control['zoneRevision'],
            1,
            0x7fffffffffffffff,
          ),
        );
      })
      .toList(growable: false);
  return IrrigationSourceSettings(
    revision: _integer(raw['revision'], 1, 0x7fffffffffffffff),
    serviceId: _id(raw['serviceId']),
    serviceRevision: _integer(raw['serviceRevision'], 1, 0x7fffffffffffffff),
    weatherEntityId: _text(raw['weatherEntityId'], 128),
    leakEntityId: _text(raw['leakEntityId'], 128),
    dailyWaterEntityId: _text(raw['dailyWaterEntityId'], 128),
    targetMoisturePermille: _integer(raw['targetMoisturePermille'], 1, 1000),
    soilMaxAgeMs: _integer(raw['soilMaxAgeMs'], 1000, 86400000),
    safetyMaxAgeMs: _integer(raw['safetyMaxAgeMs'], 1000, 3600000),
    forecastMaxAgeMs: _integer(raw['forecastMaxAgeMs'], 60000, 172800000),
    rainDeferralMilliMm: _integer(raw['rainDeferralMilliMm'], 0, 1000000),
    freezeThresholdMilliC: _integer(
      raw['freezeThresholdMilliC'],
      -50000,
      20000,
    ),
    windLimitMilliMps: _integer(raw['windLimitMilliMps'], 0, 100000),
    previewTtlMs: _integer(raw['previewTtlMs'], 1000, 60000),
    dailyLimitMl: _integer(raw['dailyLimitMl'], 0, 10000000000),
    priceMicrosPerLiter: _integer(raw['priceMicrosPerLiter'], 0, 1000000000),
    zones: List.unmodifiable(zones),
  );
}

IrrigationControllerSettings _controller(Map<String, dynamic> response) {
  _keys(response, const {'schemaVersion', 'controller'});
  if (response['schemaVersion'] != 1) _invalid();
  final raw = _object(response['controller']);
  _keys(raw, const {
    'schemaVersion',
    'controllerId',
    'revision',
    'sourceRevision',
    'stations',
    'endpointConfigured',
    'passwordConfigured',
  });
  final stations = raw['stations'];
  if (raw['schemaVersion'] != 1 ||
      raw['endpointConfigured'] != true ||
      raw['passwordConfigured'] != true ||
      stations is! List ||
      stations.isEmpty ||
      stations.length > 32) {
    _invalid();
  }
  final result = <String, int>{};
  for (final item in stations) {
    final station = _object(item);
    _keys(station, const {'zoneId', 'expectedZoneRevision', 'stationIndex'});
    final zoneId = _id(station['zoneId']);
    if (result.containsKey(zoneId)) _invalid();
    result[zoneId] = _integer(station['stationIndex'], 0, 255);
    _integer(station['expectedZoneRevision'], 1, 0x7fffffffffffffff);
  }
  return IrrigationControllerSettings(
    revision: _integer(raw['revision'], 1, 0x7fffffffffffffff),
    sourceRevision: _integer(raw['sourceRevision'], 1, 0x7fffffffffffffff),
    stationIndexes: Map.unmodifiable(result),
  );
}
