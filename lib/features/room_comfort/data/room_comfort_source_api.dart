import '../../home_resources/domain/home_resource_models.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../../server/services/domain/server_service_models.dart';
import '../domain/room_comfort_source_models.dart';

final class AccountRoomComfortSourceApi {
  AccountRoomComfortSourceApi({required this.account, required this.isCurrent});

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

  Future<RoomComfortSetupCatalog> load() =>
      account.withSession((api, session) async {
        _check(session);
        final context = session.context!;
        final root =
            '/room-comfort/${context.coreId}/${context.homeId}/configuration';
        final setup = _object(
          await api.request('GET', '$root/setup', token: session.accessToken),
        );
        _keys(setup, const {'schemaVersion', 'services', 'rooms', 'areas'});
        if (setup['schemaVersion'] != 1) _invalid();
        final servicesRaw = setup['services'];
        final roomsRaw = setup['rooms'];
        final areasRaw = setup['areas'];
        if (servicesRaw is! List ||
            servicesRaw.length > 128 ||
            roomsRaw is! List ||
            roomsRaw.length > 100 ||
            areasRaw is! List ||
            areasRaw.length > 100) {
          _invalid();
        }
        final services = servicesRaw
            .map((raw) {
              final service = ServerService.fromJson(_object(raw));
              if (service.kind != ServerServiceKind.homeAssistant ||
          service.verification.state !=
              ServerServiceVerificationState.authenticated ||
          service.revision > _maxSafeInteger ||
                  service.credentialKeys.length != 1 ||
                  service.credentialKeys.single != 'token') {
                _invalid();
              }
              return service;
            })
            .toList(growable: false);
        final rooms = roomsRaw
            .map(
              (raw) =>
                  HomeResourceRecord.fromJson(raw, expectedContext: context),
            )
            .toList(growable: false);
        final areas = areasRaw
            .map(
              (raw) =>
                  HomeResourceRecord.fromJson(raw, expectedContext: context),
            )
            .toList(growable: false);
    if (rooms.any((value) => value.kind != HomeResourceKind.room) ||
        areas.any((value) => value.kind != HomeResourceKind.resource) ||
        rooms.any((value) => value.revision > _maxSafeInteger) ||
        areas.any((value) => value.revision > _maxSafeInteger)) {
          _invalid();
        }
        RoomComfortSourceConfiguration? configuration;
        try {
          final response = _object(
            await api.request('GET', root, token: session.accessToken),
          );
          configuration = _configuration(response);
        } on LarenorServerException catch (error) {
          if (error.code != 'comfort_source_not_configured' &&
              error.code != 'conflict') {
            rethrow;
          }
        }
        _check(session);
        return RoomComfortSetupCatalog(
          services: List.unmodifiable(services),
          rooms: List.unmodifiable(rooms),
          areas: List.unmodifiable(areas),
          configuration: configuration,
        );
      });

  Future<RoomComfortEntityCatalog> entities(ServerService service) =>
      account.withSession((api, session) async {
        _check(session);
        final context = session.context!;
        final response = _object(
          await api.request(
            'GET',
            '/room-comfort/${context.coreId}/${context.homeId}'
                '/configuration/entities/${service.id}/${service.revision}',
            token: session.accessToken,
          ),
        );
        _keys(response, const {'schemaVersion', 'entities'});
        if (response['schemaVersion'] != 1) _invalid();
        final raw = _object(response['entities']);
        _keys(raw, const {
          'climate',
          'cover',
          'sensor',
          'binary_sensor',
          'weather',
        });
        _check(session);
        return RoomComfortEntityCatalog(
          climates: _entities(raw['climate'], 'climate'),
          covers: _entities(raw['cover'], 'cover'),
          sensors: _entities(raw['sensor'], 'sensor'),
          binarySensors: _entities(raw['binary_sensor'], 'binary_sensor'),
          weather: _entities(raw['weather'], 'weather'),
        );
      });

  Future<RoomComfortSourceConfiguration> save(Map<String, Object?> body) =>
      account.withSession((api, session) async {
        _check(session);
        final context = session.context!;
        final response = _object(
          await api.request(
            'PUT',
            '/room-comfort/${context.coreId}/${context.homeId}/configuration',
            token: session.accessToken,
            body: body,
          ),
        );
        _check(session);
        return _configuration(response);
      });
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

String _id(Object? value, String domain) {
  if (value is! String ||
      value.length > 128 ||
      !RegExp('^$domain\\.[a-z0-9_]{1,121}\$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

String _hex(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(value)
    ? value
    : _invalid();

int _integer(Object? value, int minimum, int maximum) =>
    value is int && value >= minimum && value <= maximum ? value : _invalid();

const _maxSafeInteger = 9007199254740991;

List<String> _entities(Object? raw, String domain) {
  if (raw is! List || raw.length > 4096) _invalid();
  final values = raw.map((value) => _id(value, domain)).toList(growable: false);
  if (values.toSet().length != values.length || !_sorted(values)) _invalid();
  return List.unmodifiable(values);
}

bool _sorted(List<String> values) {
  for (var index = 1; index < values.length; index++) {
    if (values[index - 1].compareTo(values[index]) >= 0) return false;
  }
  return true;
}

RoomComfortSourceConfiguration _configuration(Map<String, dynamic> response) {
  _keys(response, const {'schemaVersion', 'configuration'});
  if (response['schemaVersion'] != 1) _invalid();
  final raw = _object(response['configuration']);
  _keys(raw, const {
    'schemaVersion',
    'revision',
    'serviceId',
    'serviceRevision',
    'weatherEntityId',
    'aqiEntityId',
    'targetTemperatureMilliC',
    'temperatureToleranceMilliC',
    'humidityHighPermille',
    'co2HighPpm',
    'vocHighPpb',
    'outdoorAqiLimit',
    'freezeThresholdMilliC',
    'indoorMaxAgeMs',
    'outdoorMaxAgeMs',
    'occupancyMaxAgeMs',
    'previewTtlMs',
    'rooms',
  });
  final roomsRaw = raw['rooms'];
  if (raw['schemaVersion'] != 1 ||
      roomsRaw is! List ||
      roomsRaw.isEmpty ||
      roomsRaw.length > 32) {
    _invalid();
  }
  final rooms = roomsRaw
      .map((value) {
        final room = _object(value);
        _keys(room, const {
          'roomId',
          'roomRevision',
          'areaId',
          'areaRevision',
          'climateEntityId',
          'windowEntityId',
          'temperatureEntityId',
          'humidityEntityId',
          'co2EntityId',
          'vocEntityId',
          'smokeEntityId',
          'occupancyEntityId',
        });
        return RoomComfortRoomSource(
          roomId: _hex(room['roomId']),
          roomRevision: _integer(room['roomRevision'], 1, _maxSafeInteger),
          areaId: _hex(room['areaId']),
          areaRevision: _integer(room['areaRevision'], 1, _maxSafeInteger),
          climateEntityId: _id(room['climateEntityId'], 'climate'),
          windowEntityId: _id(room['windowEntityId'], 'cover'),
          temperatureEntityId: _id(room['temperatureEntityId'], 'sensor'),
          humidityEntityId: _id(room['humidityEntityId'], 'sensor'),
          co2EntityId: _id(room['co2EntityId'], 'sensor'),
          vocEntityId: _id(room['vocEntityId'], 'sensor'),
          smokeEntityId: _id(room['smokeEntityId'], 'binary_sensor'),
          occupancyEntityId: _id(room['occupancyEntityId'], 'binary_sensor'),
        );
      })
      .toList(growable: false);
  return RoomComfortSourceConfiguration(
    revision: _integer(raw['revision'], 1, _maxSafeInteger),
    serviceId: _hex(raw['serviceId']),
    serviceRevision: _integer(raw['serviceRevision'], 1, _maxSafeInteger),
    weatherEntityId: _id(raw['weatherEntityId'], 'weather'),
    aqiEntityId: _id(raw['aqiEntityId'], 'sensor'),
    targetTemperatureMilliC: _integer(
      raw['targetTemperatureMilliC'],
      5000,
      35000,
    ),
    temperatureToleranceMilliC: _integer(
      raw['temperatureToleranceMilliC'],
      100,
      10000,
    ),
    humidityHighPermille: _integer(raw['humidityHighPermille'], 1, 1000),
    co2HighPpm: _integer(raw['co2HighPpm'], 400, 10000),
    vocHighPpb: _integer(raw['vocHighPpb'], 1, 100000),
    outdoorAqiLimit: _integer(raw['outdoorAqiLimit'], 1, 500),
    freezeThresholdMilliC: _integer(
      raw['freezeThresholdMilliC'],
      -50000,
      15000,
    ),
    indoorMaxAgeMs: _integer(raw['indoorMaxAgeMs'], 1000, 86400000),
    outdoorMaxAgeMs: _integer(raw['outdoorMaxAgeMs'], 1000, 86400000),
    occupancyMaxAgeMs: _integer(raw['occupancyMaxAgeMs'], 1000, 86400000),
    previewTtlMs: _integer(raw['previewTtlMs'], 1000, 60000),
    rooms: List.unmodifiable(rooms),
  );
}
