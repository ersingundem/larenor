import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/sound_events/data/core_sound_event_api.dart';
import 'package:larenor/features/sound_events/domain/sound_event_models.dart';

const _core = '11111111111111111111111111111111';
const _home = '22222222222222222222222222222222';
const _account = '33333333333333333333333333333333';
const _family = '44444444444444444444444444444444';
const _room = '55555555555555555555555555555555';
const _device = '66666666666666666666666666666666';
const _event = '77777777777777777777777777777777';
const _access = 'sound_event_loopback_access_token_12345678';
const _refresh = 'sound_event_loopback_refresh_token_1234567';

final class _Store implements ServerSessionPersistence {
  ServerSession? value;
  @override
  Future<ServerSession?> read() async => value;
  @override
  Future<void> write(ServerSession? session) async => value = session;
}

final class _SoundCore {
  _SoundCore._(this.server) {
    unawaited(_serve());
  }

  final HttpServer server;
  int repositoryRevision = 2, policyRevision = 1, eventRevision = 1;
  bool acknowledged = false;
  bool notificationsEnabled = false, barkEnabled = true, noiseEnabled = true;
  int? mutedUntil;
  String? feedback;
  int reads = 0, policyWrites = 0, feedbackWrites = 0, acknowledgements = 0;
  Completer<void>? readEntered, readBarrier;

  String get baseUrl => 'http://127.0.0.1:${server.port}';
  static Future<_SoundCore> start() async =>
      _SoundCore._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Future<void> _serve() async {
    await for (final request in server) {
      unawaited(_handle(request).catchError((Object _) {}));
    }
  }

  Future<Map<String, dynamic>> _body(HttpRequest request) async =>
      jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    if (request.method == 'POST' && path == '/api/v1/auth/login') {
      await _body(request);
      return _json(request, {
        'accessToken': _access,
        'refreshToken': _refresh,
        'expiresIn': 3600,
        'sessionFamilyId': _family,
        'user': {
          'id': _account,
          'username': 'admin',
          'role': 'admin',
          'mustChangePassword': false,
        },
      });
    }
    if (request.headers.value(HttpHeaders.authorizationHeader) !=
        'Bearer $_access') {
      return _error(request, 401);
    }
    if (request.method == 'GET' && path == '/api/v1/context') {
      return _json(request, {
        'schemaVersion': 1,
        'coreId': _core,
        'homeId': _home,
      });
    }
    final root = '/api/v1/sound-events/$_core/$_home';
    if (request.method == 'GET' && path == root) {
      reads++;
      readEntered?.complete();
      await readBarrier?.future;
      return _json(request, _snapshot());
    }
    if (request.method == 'PUT' && path == '$root/policy') {
      policyWrites++;
      final body = await _body(request);
      if (body['expectedRepositoryRevision'] != repositoryRevision ||
          body['expectedPolicyRevision'] != policyRevision ||
          body['sourceClipRetention'] != 'never') {
        return _error(request, 409);
      }
      repositoryRevision++;
      policyRevision++;
      notificationsEnabled = body['notificationsEnabled'] as bool;
      barkEnabled = body['barkEnabled'] as bool;
      noiseEnabled = body['noiseEnabled'] as bool;
      mutedUntil = body['mutedUntilMs'] as int?;
      return _json(request, {
        'schemaVersion': 1,
        'requestId': body['requestId'],
        'accountId': _account,
        'sessionFamilyId': _family,
        'repositoryRevision': repositoryRevision,
        'policy': _policy(),
      });
    }
    if (request.method == 'POST' && path == '$root/$_event/feedback') {
      feedbackWrites++;
      final body = await _body(request);
      if (body['expectedRepositoryRevision'] != repositoryRevision ||
          body['expectedEventRevision'] != eventRevision ||
          body['classification'] != 'false_alarm') {
        return _error(request, 409);
      }
      repositoryRevision++;
      eventRevision++;
      feedback = 'false_alarm';
      return _json(request, {
        'schemaVersion': 1,
        'requestId': body['requestId'],
        'eventId': _event,
        'accountId': _account,
        'sessionFamilyId': _family,
        'repositoryRevision': repositoryRevision,
        'eventRevision': eventRevision,
        'classification': feedback,
      });
    }
    if (request.method == 'POST' && path == '$root/$_event/acknowledgements') {
      acknowledgements++;
      final body = await _body(request);
      if (body['expectedRepositoryRevision'] != repositoryRevision ||
          body['expectedEventRevision'] != eventRevision) {
        return _error(request, 409);
      }
      repositoryRevision++;
      eventRevision++;
      acknowledged = true;
      return _json(request, {
        'schemaVersion': 1,
        'requestId': body['requestId'],
        'eventId': _event,
        'coreId': _core,
        'homeId': _home,
        'accountId': _account,
        'sessionFamilyId': _family,
        'repositoryRevision': repositoryRevision,
        'eventRevision': eventRevision,
        'acknowledged': true,
      });
    }
    return _error(request, 404);
  }

  Map<String, dynamic> _policy() => {
    'schemaVersion': 1,
    'revision': policyRevision,
    'notificationsEnabled': notificationsEnabled,
    'barkEnabled': barkEnabled,
    'noiseEnabled': noiseEnabled,
    'mutedUntilMs': mutedUntil,
    'sourceClipRetention': 'never',
  };

  Map<String, dynamic> _snapshot() => {
    'schemaVersion': 2,
    'authority': {
      'schemaVersion': 1,
      'coreId': _core,
      'homeId': _home,
      'accountId': _account,
      'sessionFamilyId': _family,
      'accountRevision': 1,
      'repositoryRevision': repositoryRevision,
      'canRead': true,
      'canAcknowledge': true,
    },
    'repositoryRevision': repositoryRevision,
    'policy': _policy(),
    'sourceStatus': {
      'schemaVersion': 1,
      'state': 'ready',
      'capabilityRevision': 1,
      'providerRevision': 2,
      'modelRevision': 3,
      'lastObservationAtMs': 10000,
      'freshnessDeadlineMs': 10000000000000,
      'silenceProven': false,
      'clipAvailable': false,
    },
    'events': [
      {
        'schemaVersion': 1,
        'eventId': _event,
        'roomId': _room,
        'deviceId': _device,
        'className': 'bark',
        'confidence': .91,
        'observedAtMs': 10000,
        'retentionExpiresAtMs': 10000000000000,
        'eventRevision': eventRevision,
        'acknowledged': acknowledged,
        'automationVerified': true,
        'durationMs': 1800,
        'feedback': feedback,
        'notificationEligible': false,
      },
    ],
  };

  Future<void> close() => server.close(force: true);
}

void _json(HttpRequest request, Object body, [int status = 200]) {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
  unawaited(request.response.close());
}

void _error(HttpRequest request, int status) => _json(request, {
  'error': {'code': 'conflict'},
}, status);

Future<ServerAccountController> _signIn(_SoundCore core) async {
  final account = ServerAccountController(
    store: _Store(),
    apiFactory: (endpoint) => LarenorServerApi(endpoint: endpoint),
  );
  await account.signIn(
    baseUrl: core.baseUrl,
    username: 'admin',
    password: 'synthetic-password',
    deviceName: 'test-tablet',
  );
  return account;
}

void main() {
  setUpAll(() => HttpOverrides.global = null);

  test('production client enforces private policy, false-alarm, acknowledgement, and readback over loopback Core', () async {
    final core = await _SoundCore.start();
    addTearDown(core.close);
    final account = await _signIn(core);
    addTearDown(account.dispose);
    final api = CoreSoundEventApi(
      account: account,
      isCurrent: () => true,
      random: Random(45),
    );

    var current = await api.bootstrap();
    expect(current.sourceStatus.state, 'ready');
    expect(current.sourceStatus.silenceProven, isFalse);
    expect(current.sourceStatus.clipAvailable, isFalse);
    expect(current.policy.sourceClipRetention, 'never');
    expect(current.events.single.duration, const Duration(milliseconds: 1800));

    final policy = await api.updatePolicy(
      current.authority,
      current,
      notificationsEnabled: true,
      barkEnabled: true,
      noiseEnabled: false,
      mutedUntil: DateTime.fromMillisecondsSinceEpoch(100000, isUtc: true),
    );
    expect(policy.exactFor(current.authority, current), isTrue);
    current = await api.load(
      current.authority.withRepositoryRevision(policy.repositoryRevision),
      const SoundEventFilter(),
    );
    expect(current.policy.notificationsEnabled, isTrue);
    expect(current.policy.noiseEnabled, isFalse);
    expect(current.policy.sourceClipRetention, 'never');

    final falseAlarm = await api.feedback(
      current.authority,
      current,
      current.events.single,
      'false_alarm',
    );
    expect(
      falseAlarm.exactFor(
        current.authority,
        current,
        current.events.single,
        'false_alarm',
      ),
      isTrue,
    );
    current = await api.load(
      current.authority.withRepositoryRevision(falseAlarm.repositoryRevision),
      const SoundEventFilter(),
    );
    expect(current.events.single.feedback, 'false_alarm');

    final acknowledgement = await api.acknowledge(
      current.authority,
      current,
      current.events.single,
    );
    expect(
      acknowledgement.exactFor(
        current.authority,
        current,
        current.events.single,
      ),
      isTrue,
    );
    final readback = await api.load(
      current.authority.withRepositoryRevision(
        acknowledgement.repositoryRevision,
      ),
      const SoundEventFilter(),
    );
    expect(readback.events.single.acknowledged, isTrue);
    expect(core.policyWrites, 1);
    expect(core.feedbackWrites, 1);
    expect(core.acknowledgements, 1);
    expect(core.reads, 4);
  });

  test(
    'late classifier snapshot is discarded after route retirement',
    () async {
      final core = await _SoundCore.start();
      addTearDown(core.close);
      final account = await _signIn(core);
      addTearDown(account.dispose);
      var current = true;
      core.readEntered = Completer<void>();
      core.readBarrier = Completer<void>();
      final api = CoreSoundEventApi(account: account, isCurrent: () => current);
      final pending = api.bootstrap();
      await core.readEntered!.future;
      current = false;
      core.readBarrier!.complete();
      await expectLater(
        pending,
        throwsA(
          isA<LarenorServerException>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
      expect(api.boundSession, isNull);
    },
  );
}
