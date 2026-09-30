import 'dart:math';

import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/sound_event_models.dart';
import '../domain/sound_event_source_models.dart';
import 'sound_event_controller.dart';

abstract interface class SoundSourceConfigurationApi {
  Future<SoundSourceSetup> loadSourceSetup();
  Future<SoundSourceSetup> discoverSourceSetup();
  Future<SoundSourceSetup> configureSource({
    required SoundSourceSetup current,
    required SoundSourceChoice camera,
    required SoundSourceChoice room,
    required List<String> barkLabels,
    required List<String> noiseLabels,
    required bool consentGranted,
    required int retentionSeconds,
  });
}

final class CoreSoundEventApi
    implements
        SoundEventControlApi,
        SoundEventSourceApi,
        SoundSourceConfigurationApi {
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

  @override
  Future<SoundSourceSetup> loadSourceSetup() => _bound((api, session) async {
    return _decodeSourceSetup(
      await api.request(
        'GET',
        '${_root(session.context!)}/source',
        token: session.accessToken,
      ),
      session.user.id,
    );
  });

  @override
  Future<SoundSourceSetup> discoverSourceSetup() =>
      _bound((api, session) async {
        return _decodeSourceSetup(
          await api.request(
            'POST',
            '${_root(session.context!)}/source/discovery',
            token: session.accessToken,
          ),
          session.user.id,
        );
      });

  @override
  Future<SoundSourceSetup> configureSource({
    required SoundSourceSetup current,
    required SoundSourceChoice camera,
    required SoundSourceChoice room,
    required List<String> barkLabels,
    required List<String> noiseLabels,
    required bool consentGranted,
    required int retentionSeconds,
  }) => _bound((api, session) async {
    final value = _decodeSourceSetup(
      await api.request(
        'PUT',
        '${_root(session.context!)}/source',
        token: session.accessToken,
        body: {
          'schemaVersion': 1,
          'expectedRevision': current.configuration?.revision,
          'cameraResourceId': camera.id,
          'expectedCameraRevision': camera.revision,
          'roomId': room.id,
          'expectedRoomRevision': room.revision,
          'labels': {'bark': barkLabels, 'noise': noiseLabels},
          'consentGranted': consentGranted,
          'retentionSeconds': retentionSeconds,
        },
      ),
      session.user.id,
    );
    if (value.revision != (current.configuration?.revision ?? 0) + 1 ||
        value.configuration?.cameraResourceId != camera.id ||
        value.configuration?.roomId != room.id ||
        value.configuration?.consentGranted != consentGranted) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  });

  @override
  Future<SoundEventSnapshot> refreshSource() => _bound((api, session) async {
    final receipt = _map(
      await api.request(
        'POST',
        '${_root(session.context!)}/source/refresh',
        token: session.accessToken,
      ),
      const {
        'schemaVersion',
        'configurationRevision',
        'importedEvents',
        'reviewedRecords',
      },
    );
    if (_integer(receipt['schemaVersion']) != 1 ||
        _integer(receipt['configurationRevision']) < 1 ||
        _bounded(receipt['importedEvents'], 0, 256) < 0 ||
        _bounded(receipt['reviewedRecords'], 0, 256) < 0) {
      throw const LarenorServerException('invalid_response');
    }
    final snapshot = _decodeSnapshot(
      await api.request(
        'GET',
        _root(session.context!),
        token: session.accessToken,
      ),
      session,
    );
    if (snapshot.sourceStatus.capabilityRevision !=
        _integer(receipt['configurationRevision'])) {
      throw const LarenorServerException('invalid_response');
    }
    return snapshot;
  });

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
    final value = _map(raw, const {
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

  @override
  Future<SoundEventPolicyReceipt> updatePolicy(
    SoundEventAuthority expected,
    SoundEventSnapshot current, {
    required bool notificationsEnabled,
    required bool barkEnabled,
    required bool noiseEnabled,
    required DateTime? mutedUntil,
  }) => _bound((api, session) async {
    if (current.authority != expected) {
      throw const LarenorServerException('cancelled');
    }
    final requestId = _requestId();
    final muteMs = mutedUntil?.toUtc().millisecondsSinceEpoch;
    final value = _map(
      await api.request(
        'PUT',
        '${_root(session.context!)}/policy',
        token: session.accessToken,
        body: {
          'schemaVersion': 1,
          'requestId': requestId,
          'expectedRepositoryRevision': current.repositoryRevision,
          'expectedPolicyRevision': current.policy.revision,
          'notificationsEnabled': notificationsEnabled,
          'barkEnabled': barkEnabled,
          'noiseEnabled': noiseEnabled,
          'mutedUntilMs': muteMs,
          'sourceClipRetention': 'never',
        },
      ),
      const {
        'schemaVersion',
        'requestId',
        'accountId',
        'sessionFamilyId',
        'repositoryRevision',
        'policy',
      },
    );
    final policy = _decodePolicy(value['policy']);
    if (_integer(value['schemaVersion']) != 1 ||
        _identity(value['requestId']) != requestId ||
        _identity(value['accountId']) != expected.accountId ||
        _identity(value['sessionFamilyId']) != expected.sessionFamilyId ||
        _integer(value['repositoryRevision']) !=
            current.repositoryRevision + 1 ||
        policy.revision != current.policy.revision + 1 ||
        policy.notificationsEnabled != notificationsEnabled ||
        policy.barkEnabled != barkEnabled ||
        policy.noiseEnabled != noiseEnabled ||
        policy.mutedUntil?.millisecondsSinceEpoch != muteMs) {
      throw const LarenorServerException('invalid_response');
    }
    return SoundEventPolicyReceipt(
      requestId: requestId,
      accountId: expected.accountId,
      sessionFamilyId: expected.sessionFamilyId,
      repositoryRevision: _integer(value['repositoryRevision']),
      policy: policy,
    );
  });

  @override
  Future<SoundEventFeedbackReceipt> feedback(
    SoundEventAuthority expected,
    SoundEventSnapshot current,
    SoundEventItem event,
    String classification,
  ) => _bound((api, session) async {
    if (current.authority != expected ||
        !current.events.any((candidate) => identical(candidate, event)) ||
        !const {'false_alarm', 'confirmed'}.contains(classification)) {
      throw const LarenorServerException('cancelled');
    }
    final requestId = _requestId();
    final value = _map(
      await api.request(
        'POST',
        '${_root(session.context!)}/${event.eventId}/feedback',
        token: session.accessToken,
        body: {
          'schemaVersion': 1,
          'requestId': requestId,
          'expectedRepositoryRevision': current.repositoryRevision,
          'expectedEventRevision': event.eventRevision,
          'classification': classification,
        },
      ),
      const {
        'schemaVersion',
        'requestId',
        'eventId',
        'accountId',
        'sessionFamilyId',
        'repositoryRevision',
        'eventRevision',
        'classification',
      },
    );
    if (_integer(value['schemaVersion']) != 1 ||
        _identity(value['requestId']) != requestId ||
        _identity(value['eventId']) != event.eventId ||
        _identity(value['accountId']) != expected.accountId ||
        _identity(value['sessionFamilyId']) != expected.sessionFamilyId ||
        _integer(value['repositoryRevision']) !=
            current.repositoryRevision + 1 ||
        _integer(value['eventRevision']) != event.eventRevision + 1 ||
        value['classification'] != classification) {
      throw const LarenorServerException('invalid_response');
    }
    return SoundEventFeedbackReceipt(
      requestId: requestId,
      eventId: event.eventId,
      accountId: expected.accountId,
      sessionFamilyId: expected.sessionFamilyId,
      repositoryRevision: _integer(value['repositoryRevision']),
      eventRevision: _integer(value['eventRevision']),
      classification: classification,
    );
  });

  SoundEventSnapshot _decodeSnapshot(Object? raw, ServerSession session) {
    final loose = serverObject(raw);
    final version = _integer(loose['schemaVersion']);
    final value = switch (version) {
      1 => _map(loose, const {
        'schemaVersion',
        'authority',
        'repositoryRevision',
        'events',
      }),
      2 => _map(loose, const {
        'schemaVersion',
        'authority',
        'repositoryRevision',
        'policy',
        'sourceStatus',
        'events',
      }),
      _ => throw const LarenorServerException('invalid_response'),
    };
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
    final events = list.map(_decodeEvent).toList(growable: false);
    final revision = _integer(value['repositoryRevision']);
    if (revision != authority.repositoryRevision) {
      throw const LarenorServerException('invalid_response');
    }
    return SoundEventSnapshot(
      authority: authority,
      repositoryRevision: revision,
      events: events,
      policy: version == 2
          ? _decodePolicy(value['policy'])
          : const SoundEventPolicy.disabled(),
      sourceStatus: version == 2
          ? _decodeSourceStatus(value['sourceStatus'])
          : const SoundSourceStatus.unavailable(),
    );
  }

  SoundEventItem _decodeEvent(Object? raw) {
    final loose = serverObject(raw);
    const oldKeys = {
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
    };
    const newKeys = {
      ...oldKeys,
      'durationMs',
      'feedback',
      'notificationEligible',
    };
    final modern = loose.containsKey('durationMs');
    final event = _map(loose, modern ? newKeys : oldKeys);
    final confidence = event['confidence'];
    final className = event['className'];
    final feedback = modern ? event['feedback'] : null;
    if (_integer(event['schemaVersion']) != 1 ||
        confidence is! num ||
        !confidence.isFinite ||
        confidence < 0 ||
        confidence > 1 ||
        (className != 'bark' && className != 'noise') ||
        event['acknowledged'] is! bool ||
        event['automationVerified'] is! bool ||
        (modern && event['notificationEligible'] is! bool) ||
        (feedback != null &&
            feedback != 'false_alarm' &&
            feedback != 'confirmed')) {
      throw const LarenorServerException('invalid_response');
    }
    final duration = modern ? _integer(event['durationMs']) : 1000;
    if (duration < 100 || duration > 60000) {
      throw const LarenorServerException('invalid_response');
    }
    return SoundEventItem(
      eventId: _identity(event['eventId']),
      roomId: _identity(event['roomId']),
      deviceId: _identity(event['deviceId']),
      className: className as String,
      confidence: confidence.toDouble(),
      observedAt: _time(event['observedAtMs']),
      retentionExpiresAt: _time(event['retentionExpiresAtMs']),
      eventRevision: _integer(event['eventRevision']),
      acknowledged: event['acknowledged'] as bool,
      automationVerified: event['automationVerified'] as bool,
      duration: Duration(milliseconds: duration),
      feedback: feedback as String?,
      notificationEligible: modern && event['notificationEligible'] as bool,
    );
  }

  SoundEventPolicy _decodePolicy(Object? raw) {
    final value = _map(raw, const {
      'schemaVersion',
      'revision',
      'notificationsEnabled',
      'barkEnabled',
      'noiseEnabled',
      'mutedUntilMs',
      'sourceClipRetention',
    });
    if (_integer(value['schemaVersion']) != 1 ||
        value['notificationsEnabled'] is! bool ||
        value['barkEnabled'] is! bool ||
        value['noiseEnabled'] is! bool ||
        value['sourceClipRetention'] != 'never' ||
        (value['mutedUntilMs'] != null && value['mutedUntilMs'] is! int)) {
      throw const LarenorServerException('invalid_response');
    }
    return SoundEventPolicy(
      revision: _integer(value['revision']),
      notificationsEnabled: value['notificationsEnabled'] as bool,
      barkEnabled: value['barkEnabled'] as bool,
      noiseEnabled: value['noiseEnabled'] as bool,
      mutedUntil: value['mutedUntilMs'] == null
          ? null
          : _time(value['mutedUntilMs']),
      sourceClipRetention: 'never',
    );
  }

  SoundSourceStatus _decodeSourceStatus(Object? raw) {
    final value = _map(raw, const {
      'schemaVersion',
      'state',
      'capabilityRevision',
      'providerRevision',
      'modelRevision',
      'lastObservationAtMs',
      'freshnessDeadlineMs',
      'silenceProven',
      'clipAvailable',
    });
    final state = value['state'];
    if (_integer(value['schemaVersion']) != 1 ||
        !const {'ready', 'degraded', 'stale', 'unavailable'}.contains(state) ||
        value['silenceProven'] != false ||
        value['clipAvailable'] is! bool) {
      throw const LarenorServerException('invalid_response');
    }
    int? revision(String key) =>
        value[key] == null ? null : _integer(value[key]);
    DateTime? time(String key) => value[key] == null ? null : _time(value[key]);
    final result = SoundSourceStatus(
      state: state as String,
      capabilityRevision: revision('capabilityRevision'),
      providerRevision: revision('providerRevision'),
      modelRevision: revision('modelRevision'),
      lastObservationAt: time('lastObservationAtMs'),
      freshnessDeadline: time('freshnessDeadlineMs'),
      silenceProven: false,
      clipAvailable: value['clipAvailable'] as bool,
    );
    final revisions = [
      result.capabilityRevision,
      result.providerRevision,
      result.modelRevision,
    ];
    if (result.state == 'unavailable') {
      if (revisions.any((item) => item != null) ||
          result.lastObservationAt != null ||
          result.freshnessDeadline != null ||
          result.clipAvailable) {
        throw const LarenorServerException('invalid_response');
      }
    } else if (revisions.any((item) => item == null) ||
        result.freshnessDeadline == null) {
      throw const LarenorServerException('invalid_response');
    }
    return result;
  }

  SoundSourceSetup _decodeSourceSetup(Object? raw, String expectedOwner) {
    final value = _map(raw, const {
      'schemaVersion',
      'revision',
      'discoveryVerified',
      'configuration',
      'cameras',
      'rooms',
    });
    if (_integer(value['schemaVersion']) != 1 ||
        value['discoveryVerified'] is! bool) {
      throw const LarenorServerException('invalid_response');
    }
    List<SoundSourceChoice> choices(Object? raw, int limit) {
      if (raw is! List || raw.length > limit) {
        throw const LarenorServerException('invalid_response');
      }
      final ids = <String>{};
      return raw
          .map((item) {
            final choice = _map(item, const {
              'id',
              'revision',
              'label',
              'audioLabels',
            });
            final labels = choice['audioLabels'];
            if (choice['label'] is! String ||
                (choice['label'] as String).isEmpty ||
                (choice['label'] as String).length > 80 ||
                labels is! List ||
                labels.length > 256 ||
                labels.any(
                  (label) =>
                      label is! String || label.isEmpty || label.length > 64,
                )) {
              throw const LarenorServerException('invalid_response');
            }
            final id = _identity(choice['id']);
            if (!ids.add(id)) {
              throw const LarenorServerException('invalid_response');
            }
            return SoundSourceChoice(
              id: id,
              revision: _integer(choice['revision']),
              label: choice['label'] as String,
              audioLabels: List<String>.unmodifiable(labels.cast<String>()),
            );
          })
          .toList(growable: false);
    }

    final cameras = choices(value['cameras'], 16);
    final rooms = choices(value['rooms'], 128);
    final configuration = value['configuration'] == null
        ? null
        : _decodeSourceConfiguration(value['configuration'], expectedOwner);
    final revision = _bounded(value['revision'], 0, 0x7fffffffffffffff);
    if (revision != (configuration?.revision ?? 0)) {
      throw const LarenorServerException('invalid_response');
    }
    return SoundSourceSetup(
      revision: revision,
      discoveryVerified: value['discoveryVerified'] as bool,
      configuration: configuration,
      cameras: cameras,
      rooms: rooms,
    );
  }

  SoundSourceConfiguration _decodeSourceConfiguration(
    Object? raw,
    String expectedOwner,
  ) {
    final value = _map(raw, const {
      'schemaVersion',
      'revision',
      'ownerId',
      'cameraResourceId',
      'cameraRevision',
      'roomId',
      'roomRevision',
      'frigateCamera',
      'providerRevision',
      'labels',
      'consentGranted',
      'consentRevision',
      'retentionSeconds',
      'configuredAtMs',
    });
    final labels = _map(value['labels'], const {'bark', 'noise'});
    List<String> labelList(String key, int limit) {
      final raw = labels[key];
      if (raw is! List ||
          raw.length > limit ||
          raw.any(
            (item) => item is! String || item.isEmpty || item.length > 64,
          )) {
        throw const LarenorServerException('invalid_response');
      }
      return List<String>.unmodifiable(raw.cast<String>());
    }

    final bark = labelList('bark', 8), noise = labelList('noise', 16);
    if (_integer(value['schemaVersion']) != 1 ||
        value['consentGranted'] is! bool ||
        value['frigateCamera'] is! String ||
        bark.toSet().intersection(noise.toSet()).isNotEmpty) {
      throw const LarenorServerException('invalid_response');
    }
    if (_identity(value['ownerId']) != expectedOwner) {
      throw const LarenorServerException('invalid_response');
    }
    _integer(value['providerRevision']);
    _integer(value['consentRevision']);
    _time(value['configuredAtMs']);
    return SoundSourceConfiguration(
      revision: _integer(value['revision']),
      cameraResourceId: _identity(value['cameraResourceId']),
      cameraRevision: _integer(value['cameraRevision']),
      roomId: _identity(value['roomId']),
      roomRevision: _integer(value['roomRevision']),
      labels: Map.unmodifiable({'bark': bark, 'noise': noise}),
      consentGranted: value['consentGranted'] as bool,
      retentionSeconds: _bounded(value['retentionSeconds'], 60, 604800),
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

int _bounded(Object? value, int minimum, int maximum) {
  if (value is! int || value < minimum || value > maximum) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}

DateTime _time(Object? value) {
  if (value is! int || value < 0 || value > 0x7fffffffffffffff) {
    throw const LarenorServerException('invalid_response');
  }
  return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
}
