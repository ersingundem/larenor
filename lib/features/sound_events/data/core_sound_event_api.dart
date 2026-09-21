import 'dart:math';

import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/sound_event_models.dart';
import 'sound_event_controller.dart';

final class CoreSoundEventApi implements SoundEventApi {
  CoreSoundEventApi({
    required this.account,
    required this.isCurrent,
    Random? random,
  }) : _random = random ?? Random.secure();

  final ServerAccountController account;
  final bool Function() isCurrent;
  final Random _random;
  ServerSession? _session;
  bool _retired = false;

  ServerSession? get boundSession => _session;
  void retire() {
    _retired = true;
    _session = null;
  }

  void _check() {
    try {
      if (!_retired && isCurrent()) return;
    } catch (_) {}
    retire();
    throw const LarenorServerException('cancelled');
  }

  String _root(ServerContext value) =>
      '/sound-events/${value.coreId}/${value.homeId}';
  String _requestId() =>
      List.generate(32, (_) => _random.nextInt(16).toRadixString(16)).join();

  Future<SoundEventSnapshot> bootstrap() async {
    _check();
    if (_session != null) throw const LarenorServerException('cancelled');
    final result = await account.withSession((api, session) async {
      _check();
      if (session.context == null) {
        throw const LarenorServerException('forbidden');
      }
      _session = session;
      return _decodeSnapshot(
        await api.request(
          'GET',
          _root(session.context!),
          token: session.accessToken,
        ),
        session,
      );
    });
    _check();
    return result;
  }

  Future<T> _bound<T>(
    Future<T> Function(LarenorServerApi api, ServerSession session) action,
  ) async {
    _check();
    final expected = _session;
    if (expected == null) throw const LarenorServerException('cancelled');
    return account.withSession((api, session) async {
      _check();
      if (!identical(expected, session) ||
          !identical(account.session, session) ||
          session.context == null) {
        retire();
        throw const LarenorServerException('cancelled');
      }
      final result = await action(api, session);
      _check();
      if (!identical(expected, account.session)) {
        retire();
        throw const LarenorServerException('cancelled');
      }
      return result;
    });
  }

  @override
  Future<SoundEventSnapshot> load(
    SoundEventAuthority expected,
    SoundEventFilter filter,
  ) => _bound((api, session) async {
    final value = _decodeSnapshot(
      await api.request(
        'GET',
        _root(session.context!),
        token: session.accessToken,
      ),
      session,
    );
    if (value.authority != expected) {
      retire();
      throw const LarenorServerException('cancelled');
    }
    return value;
  });

  @override
  Future<SoundEventAcknowledgement> acknowledge(
    SoundEventAuthority expected,
    SoundEventSnapshot current,
    SoundEventItem event,
  ) => _bound((api, session) async {
    if (current.authority != expected ||
        !current.events.any((candidate) => identical(candidate, event))) {
      throw const LarenorServerException('cancelled');
    }
    final requestId = _requestId();
    final raw = await api.request(
      'POST',
      '${_root(session.context!)}/${event.eventId}/acknowledgements',
      token: session.accessToken,
      body: {
        'schemaVersion': 1,
        'requestId': requestId,
        'expectedRepositoryRevision': current.repositoryRevision,
        'expectedEventRevision': event.eventRevision,
      },
    );
    final value = _map(raw, {
      'schemaVersion',
      'requestId',
      'eventId',
      'coreId',
      'homeId',
      'accountId',
      'sessionFamilyId',
      'repositoryRevision',
      'eventRevision',
      'acknowledged',
    });
    final context = session.context!;
    if (_integer(value['schemaVersion']) != 1 ||
        _identity(value['requestId']) != requestId ||
        _identity(value['eventId']) != event.eventId ||
        _identity(value['coreId']) != context.coreId ||
        _identity(value['homeId']) != context.homeId ||
        _identity(value['accountId']) != session.user.id ||
        _identity(value['sessionFamilyId']) != expected.sessionFamilyId ||
        _integer(value['repositoryRevision']) !=
            current.repositoryRevision + 1 ||
        _integer(value['eventRevision']) != event.eventRevision + 1 ||
        value['acknowledged'] != true) {
      throw const LarenorServerException('invalid_response');
    }
    return SoundEventAcknowledgement(
      requestId: requestId,
      eventId: event.eventId,
      accountId: session.user.id,
      sessionFamilyId: _identity(value['sessionFamilyId']),
      repositoryRevision: _integer(value['repositoryRevision']),
      eventRevision: _integer(value['eventRevision']),
      acknowledged: true,
    );
  });

  SoundEventSnapshot _decodeSnapshot(Object? raw, ServerSession session) {
    final value = _map(raw, const {
      'schemaVersion',
      'authority',
      'repositoryRevision',
      'events',
    });
    if (_integer(value['schemaVersion']) != 1) {
      throw const LarenorServerException('invalid_response');
    }
    final context = session.context!;
    final auth = _map(value['authority'], const {
      'schemaVersion',
      'coreId',
      'homeId',
      'accountId',
      'sessionFamilyId',
      'accountRevision',
      'repositoryRevision',
      'canRead',
      'canAcknowledge',
    });
    if (_integer(auth['schemaVersion']) != 1 ||
        _identity(auth['coreId']) != context.coreId ||
        _identity(auth['homeId']) != context.homeId ||
        _identity(auth['accountId']) != session.user.id ||
        auth['canRead'] != true ||
        auth['canAcknowledge'] is! bool) {
      throw const LarenorServerException('invalid_response');
    }
    final authority = SoundEventAuthority(
      coreId: context.coreId,
      homeId: context.homeId,
      accountId: session.user.id,
      sessionFamilyId: _identity(auth['sessionFamilyId']),
      accountRevision: _integer(auth['accountRevision']),
      repositoryRevision: _integer(auth['repositoryRevision']),
      canRead: true,
      canAcknowledge: auth['canAcknowledge'] as bool,
    );
    final list = value['events'];
    if (list is! List || list.length > 100) {
      throw const LarenorServerException('invalid_response');
    }
    final events = list
        .map((rawEvent) {
          final event = _map(rawEvent, const {
            'schemaVersion',
            'eventId',
            'roomId',
            'deviceId',
            'className',
            'confidence',
            'observedAtMs',
            'retentionExpiresAtMs',
            'eventRevision',
            'acknowledged',
            'automationVerified',
          });
          final confidence = event['confidence'];
          if (_integer(event['schemaVersion']) != 1 ||
              confidence is! num ||
              !confidence.isFinite ||
              confidence < 0 ||
              confidence > 1 ||
              event['acknowledged'] is! bool ||
              event['automationVerified'] is! bool) {
            throw const LarenorServerException('invalid_response');
          }
          return SoundEventItem(
            eventId: _identity(event['eventId']),
            roomId: _identity(event['roomId']),
            deviceId: _identity(event['deviceId']),
            className: _text(event['className'], 48),
            confidence: confidence.toDouble(),
            observedAt: _time(event['observedAtMs']),
            retentionExpiresAt: _time(event['retentionExpiresAtMs']),
            eventRevision: _integer(event['eventRevision']),
            acknowledged: event['acknowledged'] as bool,
            automationVerified: event['automationVerified'] as bool,
          );
        })
        .toList(growable: false);
    final revision = _integer(value['repositoryRevision']);
    if (revision != authority.repositoryRevision) {
      throw const LarenorServerException('invalid_response');
    }
    return SoundEventSnapshot(
      authority: authority,
      repositoryRevision: revision,
      events: events,
    );
  }
}

Map<String, dynamic> _map(Object? value, Set<String> keys) {
  final result = serverObject(value);
  if (result.length != keys.length || !result.keys.toSet().containsAll(keys)) {
    throw const LarenorServerException('invalid_response');
  }
  return result;
}

String _identity(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}

int _integer(Object? value) {
  if (value is! int || value < 1 || value > 0x7fffffffffffffff) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}

String _text(Object? value, int max) {
  if (value is! String ||
      value.trim().isEmpty ||
      value.length > max ||
      value.contains(RegExp(r'[\u0000-\u001f\u007f]'))) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}

DateTime _time(Object? value) =>
    DateTime.fromMillisecondsSinceEpoch(_integer(value), isUtc: true);
