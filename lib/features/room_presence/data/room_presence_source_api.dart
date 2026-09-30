import '../../home_resources/domain/home_resource_models.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../../server/services/domain/server_service_models.dart';
import '../domain/room_presence_source_models.dart';

const _maxSafe = 9007199254740991;

abstract interface class RoomPresenceSourceApi {
  void retire();
  Future<RoomPresenceSetupCatalog> load();
  Future<List<RoomPresenceEntityCandidate>> entities(ServerService service);
  Future<RoomPresenceSourceConfiguration> save(Map<String, Object?> body);
  Future<RoomPresenceSourceConfiguration> revoke(int expectedRevision);
}

final class AccountRoomPresenceSourceApi implements RoomPresenceSourceApi {
  AccountRoomPresenceSourceApi({
    required this.account,
    required this.isCurrent,
  });
  final ServerAccountController account;
  final bool Function() isCurrent;
  ServerSession? _session;
  bool _retired = false;

  @override
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

  @override
  Future<RoomPresenceSetupCatalog> load() =>
      account.withSession((api, session) async {
        _check(session);
        final context = session.context!;
        final root =
            '/room-presence/${context.coreId}/${context.homeId}/configuration';
        final setup = _object(
          await api.request('GET', '$root/setup', token: session.accessToken),
        );
        _keys(setup, const {
          'schemaVersion',
          'services',
          'rooms',
          'provider',
          'advisoryOnly',
          'grantsAccess',
        });
        if (setup['schemaVersion'] != 1 ||
            setup['provider'] != 'home_assistant_mqtt_room' ||
            setup['advisoryOnly'] != true ||
            setup['grantsAccess'] != false ||
            setup['services'] is! List ||
            setup['rooms'] is! List ||
            (setup['services'] as List).length > 128 ||
            (setup['rooms'] as List).length > 100) {
          _invalid();
        }
        final services = (setup['services'] as List)
            .map((raw) {
              final value = ServerService.fromJson(_object(raw));
              if (value.kind != ServerServiceKind.homeAssistant ||
                  value.verification.state !=
                      ServerServiceVerificationState.authenticated ||
                  value.credentialKeys.length != 1 ||
                  value.credentialKeys.single != 'token' ||
                  value.revision > _maxSafe) {
                _invalid();
              }
              return value;
            })
            .toList(growable: false);
        final rooms = (setup['rooms'] as List)
            .map(
              (raw) =>
                  HomeResourceRecord.fromJson(raw, expectedContext: context),
            )
            .toList(growable: false);
        if (rooms.any(
          (room) =>
              room.kind != HomeResourceKind.room || room.revision > _maxSafe,
        )) {
          _invalid();
        }
        RoomPresenceSourceConfiguration? configuration;
        try {
          configuration = _configuration(
            _object(await api.request('GET', root, token: session.accessToken)),
          );
        } on LarenorServerException catch (error) {
          if (error.code != 'presence_source_not_configured' &&
              error.code != 'conflict') {
            rethrow;
          }
        }
        _check(session);
        return RoomPresenceSetupCatalog(
          services: List.unmodifiable(services),
          rooms: List.unmodifiable(rooms),
          configuration: configuration,
        );
      });

  @override
  Future<List<RoomPresenceEntityCandidate>> entities(
    ServerService service,
  ) => account.withSession((api, session) async {
    _check(session);
    final context = session.context!;
    final raw = _object(
      await api.request(
        'GET',
        '/room-presence/${context.coreId}/${context.homeId}'
            '/configuration/entities/${service.id}/${service.revision}',
        token: session.accessToken,
      ),
    );
    _keys(raw, const {'schemaVersion', 'entities'});
    final values = raw['entities'];
    if (raw['schemaVersion'] != 1 || values is! List || values.length > 4096) {
      _invalid();
    }
    final result = values
        .map((item) {
          final value = _object(item);
          _keys(value, const {
            'schemaVersion',
            'candidateId',
            'entityId',
            'name',
            'platform',
          });
          if (value['schemaVersion'] != 1 || value['platform'] != 'mqtt_room') {
            _invalid();
          }
          return RoomPresenceEntityCandidate(
            candidateId: _digest(value['candidateId']),
            entityId: _entity(value['entityId']),
            name: _label(value['name']),
          );
        })
        .toList(growable: false);
    if (result.map((item) => item.entityId).toSet().length != result.length) {
      _invalid();
    }
    _check(session);
    return List.unmodifiable(result);
  });

  @override
  Future<RoomPresenceSourceConfiguration> save(Map<String, Object?> body) =>
      account.withSession((api, session) async {
        _check(session);
        final context = session.context!;
        final response = await api.request(
          'PUT',
          '/room-presence/${context.coreId}/${context.homeId}/configuration',
          token: session.accessToken,
          body: body,
        );
        _check(session);
        return _configuration(_object(response));
      });

  @override
  Future<RoomPresenceSourceConfiguration> revoke(int expectedRevision) =>
      account.withSession((api, session) async {
        _check(session);
        if (expectedRevision < 1 || expectedRevision > _maxSafe) _invalid();
        final context = session.context!;
        final response = await api.request(
          'POST',
          '/room-presence/${context.coreId}/${context.homeId}'
              '/configuration/consent/revoke',
          token: session.accessToken,
          body: {'schemaVersion': 1, 'expectedRevision': expectedRevision},
        );
        _check(session);
        return _configuration(_object(response));
      });
}

Map<String, dynamic> _object(Object? raw) {
  if (raw is! Map<String, dynamic>) _invalid();
  return raw;
}

Never _invalid() => throw const LarenorServerException('invalid_response');

void _keys(Map<String, dynamic> value, Set<String> expected) {
  if (value.length != expected.length ||
      !value.keys.toSet().containsAll(expected)) {
    _invalid();
  }
}

String _identity(Object? raw) =>
    raw is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(raw) ? raw : _invalid();
String _digest(Object? raw) =>
    raw is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(raw) ? raw : _invalid();
String _entity(Object? raw) =>
    raw is String && RegExp(r'^sensor\.[a-z0-9_]{1,121}$').hasMatch(raw)
    ? raw
    : _invalid();
String _label(Object? raw) =>
    raw is String &&
        raw.trim().isNotEmpty &&
        raw.length <= 80 &&
        !raw.codeUnits.any((value) => value < 32 || value == 127)
    ? raw.trim()
    : _invalid();
int _revision(Object? raw) =>
    raw is int && raw >= 1 && raw <= _maxSafe ? raw : _invalid();

RoomPresenceSourceConfiguration _configuration(Map<String, dynamic> response) {
  _keys(response, const {'schemaVersion', 'configuration'});
  if (response['schemaVersion'] != 1) _invalid();
  final raw = _object(response['configuration']);
  _keys(raw, const {
    'schemaVersion',
    'revision',
    'serviceId',
    'serviceRevision',
    'entityId',
    'entityName',
    'consentActive',
    'maxSignalAgeMs',
    'rooms',
    'provider',
    'advisoryOnly',
    'grantsAccess',
  });
  final rooms = raw['rooms'];
  if (raw['schemaVersion'] != 1 ||
      raw['consentActive'] is! bool ||
      raw['provider'] != 'home_assistant_mqtt_room' ||
      raw['advisoryOnly'] != true ||
      raw['grantsAccess'] != false ||
      rooms is! List ||
      rooms.isEmpty ||
      rooms.length > 32) {
    _invalid();
  }
  final maxSignalAgeMs = raw['maxSignalAgeMs'];
  return RoomPresenceSourceConfiguration(
    revision: _revision(raw['revision']),
    serviceId: _identity(raw['serviceId']),
    serviceRevision: _revision(raw['serviceRevision']),
    entityId: _entity(raw['entityId']),
    entityName: _label(raw['entityName']),
    consentActive: raw['consentActive'] as bool,
    maxSignalAgeMs:
        maxSignalAgeMs is int &&
            maxSignalAgeMs >= 1000 &&
            maxSignalAgeMs <= 900000
        ? maxSignalAgeMs
        : _invalid(),
    rooms: List.unmodifiable(
      rooms.map((item) {
        final room = _object(item);
        _keys(room, const {'roomId', 'roomRevision', 'roomLabel'});
        return RoomPresenceConfiguredRoom(
          roomId: _identity(room['roomId']),
          roomRevision: _revision(room['roomRevision']),
          roomLabel: _label(room['roomLabel']),
        );
      }),
    ),
  );
}
