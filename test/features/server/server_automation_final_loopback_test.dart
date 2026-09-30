import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:larenor/features/server/automation_drafts/data/server_automation_draft_api.dart';
import 'package:larenor/features/server/automation_trials/data/server_automation_trial_api.dart';
import 'package:larenor/features/server/automation_trials/data/server_automation_trial_controller.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import '../../../integration_test/support/synthetic_ha_server.dart';

final _coreId = 'a' * 32;
final _homeId = 'b' * 32;
final _resourceId = '3' * 32;
final _otherResourceId = 'a' * 32;
final _serviceId = '5' * 32;
final _trialId = '6' * 32;
const _token = 'synthetic_loopback_access_token';

final class _Store implements ServerSessionPersistence {
  _Store(this.value);
  ServerSession? value;

  @override
  Future<ServerSession?> read() async => value;

  @override
  Future<void> write(ServerSession? session) async => value = session;
}

final class _AutomationCore {
  _AutomationCore._(this.server);

  final HttpServer server;
  final requests = <String>[];
  Completer<void>? replayGate;
  bool malformedDraft = false;
  bool multipleTargets = false;
  String? draftedTarget;
  bool malformedReplay = false;
  int replayRequests = 0;

  String get baseUrl => 'http://127.0.0.1:${server.port}/prefix';
  Map<String, Object?> get context => {
    'schemaVersion': 1,
    'coreId': _coreId,
    'homeId': _homeId,
  };

  static Future<_AutomationCore> start() async {
    final fixture = _AutomationCore._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    fixture.server.listen(fixture._handle);
    return fixture;
  }

  Map<String, Object?> get user => {
    'id': '1' * 32,
    'username': 'admin',
    'role': 'admin',
    'mustChangePassword': false,
  };

  Map<String, Object?> get resource => {
    'ref': {...context, 'kind': 'resource', 'id': _resourceId},
    'label': 'Reading lamp',
    'order': 0,
    'revision': 1,
    'aclRevision': 1,
    'permissions': {'read': true, 'write': true},
  };

  Map<String, Object?> get snapshot => {
    'schemaVersion': 1,
    'ref': {...context, 'kind': 'resource', 'id': _resourceId},
    'bindingId': '4' * 32,
    'bindingRevision': 1,
    'resourceRevision': 1,
    'aclRevision': 1,
    'serviceRevision': 1,
    'observedAt': '2026-09-30T08:00:00Z',
    'remainingTtlMs': 5000,
    'projection': {'kind': 'switch', 'state': 'off', 'commandAvailable': true},
  };

  Map<String, Object?> get draft => {
    'schemaVersion': 1,
    'id': '7' * 32,
    'revision': 1,
    'state': 'draft',
    'catalogVersion': 'ha-switch-actions-v1',
    'target': {'resourceId': _resourceId},
    'action': 'turn_on',
    'steps': ['validate_current_target', 'create_inert_rule'],
    'sideEffects': ['creates_automation_rule', 'does_not_execute_device'],
    'expiresAt': 1790762400.0,
    'expired': false,
    'requiresExplicitConfirmation': true,
    'deviceCommandAvailable': false,
    'rule': null,
  };

  Map<String, Object?> get rule => {
    'ruleId': '4' * 32,
    'eventKey': 'automation_triggered',
    'deviceId': _resourceId,
    'action': 'turn_on',
    'priority': 50,
    'weekdays': [0, 1, 2, 3, 4, 5, 6],
    'startMinute': 0,
    'endMinute': 1440,
  };

  Map<String, Object?> trial({bool withEvent = false}) => {
    'schemaVersion': 1,
    'id': _trialId,
    'timezone': 'Europe/Berlin',
    'localStartDate': '2025-10-26',
    'startsAtMs': 1761436800000,
    'endsAtMs': 1762045200000,
    'utcDurationSeconds': 608400,
    'simulationOnly': true,
    'adapterWriteCount': 0,
    'rules': [rule],
    'eventCount': withEvent ? 1 : 0,
    'triggeredCount': withEvent ? 1 : 0,
    'suppressedCount': 0,
    'events': withEvent
        ? [
            {
              'schemaVersion': 1,
              'source': 'synthetic',
              'eventKey': 'service_check',
              'occurredAtMs': 1761442200000,
              'localDateTime': '2025-10-26T02:30:00+01:00',
              'utcOffsetSeconds': 3600,
              'fold': 1,
              'decisions': [
                {
                  'ruleId': _serviceId,
                  'deviceId': _serviceId,
                  'action': 'turn_on',
                  'priority': 50,
                  'state': 'triggered',
                  'reason': 'winner',
                },
              ],
              'adapterWriteCount': 0,
            },
          ]
        : <Object?>[],
  };

  Map<String, Object?> replay() => {
    'schemaVersion': 1,
    'trialId': _trialId,
    'status': 'complete',
    'unknownReason': null,
    'requiredEventCount': 1,
    'availableEventCount': 1,
    'changedDecisionCount': 1,
    'decisionDiffs': [
      {
        'eventId': '8' * 32,
        'ruleId': _serviceId,
        'before': {'action': 'turn_on'},
        'after': {'action': 'turn_off'},
      },
    ],
    'deterministicFingerprint': 'd' * 64,
    'adapterWriteCount': 0,
    'queueWriteCount': 0,
  };

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    requests.add('${request.method} $path');
    Object? body;
    if (request.method != 'GET') {
      final text = await utf8.decoder.bind(request).join();
      if (text.isNotEmpty) body = jsonDecode(text);
    }
    if (path.endsWith('/auth/me')) {
      return _json(request, {'user': user});
    }
    if (path.endsWith('/context')) return _json(request, context);
    if (path.endsWith('/auth/logout')) {
      request.response.statusCode = 204;
      return request.response.close();
    }
    if (path.endsWith('/automation-drafts/$_coreId/$_homeId/actions')) {
      return _json(request, {
        'schemaVersion': 1,
        'catalogVersion': 'ha-switch-actions-v1',
        'actions': ['turn_on', 'turn_off'],
        'deviceCommandAvailable': false,
      });
    }
    if (path.endsWith('/home-resources/$_coreId/$_homeId')) {
      return _json(request, {
        'scope': context,
        'userRevision': 1,
        'entries': [
          resource,
          if (multipleTargets)
            {
              ...resource,
              'ref': {...context, 'kind': 'resource', 'id': _otherResourceId},
              'label': 'Other lamp',
            },
        ],
        'snapshot': 'c' * 64,
        'nextAfter': null,
      });
    }
    if (path.endsWith(
      '/admin/home-assistant/$_coreId/$_homeId/resources/$_resourceId/binding',
    )) {
      return _json(request, {
        'binding': {
          'schemaVersion': 1,
          'id': '4' * 32,
          'revision': 1,
          'ref': {...context, 'kind': 'resource', 'id': _resourceId},
          'serviceId': _serviceId,
          'serviceRevision': 1,
          'entityId': 'automation.welcome_home',
        },
      });
    }
    if (path.endsWith(
      '/home-assistant/$_coreId/$_homeId/resources/$_resourceId/snapshot',
    )) {
      return _json(request, {'snapshot': snapshot});
    }
    if (multipleTargets &&
        path.endsWith(
          '/home-assistant/$_coreId/$_homeId/resources/$_otherResourceId/snapshot',
        )) {
      return _json(request, {
        'snapshot': {
          ...snapshot,
          'ref': {...context, 'kind': 'resource', 'id': _otherResourceId},
        },
      });
    }
    if (path.endsWith('/automation-drafts/$_coreId/$_homeId')) {
      expect((body as Map)['transcript'], 'turn on');
      draftedTarget = body['resourceId'] as String;
      return _json(request, {
        'draft': {
          ...draft,
          'target': {'resourceId': draftedTarget},
          if (malformedDraft) 'secret': 'must-reject',
        },
      }, status: 201);
    }
    if (path.endsWith('/admin/services')) {
      return _json(request, {
        'services': [
          {
            'id': _serviceId,
            'name': 'Synthetic service',
            'kind': 'home_assistant',
            'baseUrl': 'https://service.invalid',
            'revision': 1,
            'credentialKeys': ['token'],
            'verification': {
              'state': 'never',
              'checkedAt': null,
              'version': null,
            },
          },
        ],
      });
    }
    if (path.endsWith('/automation-trials/$_coreId/$_homeId')) {
      if (request.method == 'GET') {
        return _json(request, {
          'schemaVersion': 1,
          'scope': context,
          'trials': [trial(withEvent: true)],
        });
      }
      return _json(request, {'trial': trial()}, status: 201);
    }
    if (path.endsWith(
      '/automation-trials/$_coreId/$_homeId/$_trialId/events',
    )) {
      return _json(request, {'trial': trial(withEvent: true)}, status: 201);
    }
    if (path.endsWith(
      '/automation-trials/$_coreId/$_homeId/$_trialId/replays',
    )) {
      replayRequests++;
      if (replayGate case final gate?) await gate.future;
      return _json(request, {
        'replay': {...replay(), if (malformedReplay) 'secret': 'must-reject'},
      });
    }
    request.response.statusCode = 404;
    await _json(request, {
      'error': {'code': 'not_found'},
    });
  }

  Future<void> _json(
    HttpRequest request,
    Object value, {
    int status = 200,
  }) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(value));
    await request.response.close();
  }

  Future<void> close() => server.close(force: true);
}

LarenorServerApi _api(_AutomationCore core) => LarenorServerApi(
  endpoint: ServerEndpoint(core.baseUrl),
  client: IOClient(FixtureNetwork(core.server.port).createHttpClient(null)),
  timeout: const Duration(seconds: 2),
);

ServerSession _session(_AutomationCore core) => ServerSession(
  endpoint: ServerEndpoint(core.baseUrl),
  accessToken: _token,
  refreshToken: 'synthetic_loopback_refresh_token',
  expiresAt: DateTime.utc(2027),
  user: ServerUser(
    id: '1' * 32,
    username: 'admin',
    role: ServerRole.admin,
    mustChangePassword: false,
  ),
  sessionFamilyId: '9' * 32,
  context: ServerContext.fromJson({
    'schemaVersion': 1,
    'coreId': _coreId,
    'homeId': _homeId,
  }),
);

void main() {
  test('F01 multiple targets require a choice and explicit target cannot fall back', () async {
    final core = await _AutomationCore.start();
    core.multipleTargets = true;
    final api = _api(core);
    addTearDown(() async {
      api.close();
      await core.close();
    });
    final drafts = ServerAutomationDraftApi(
      api,
      _token,
      ServerContext.fromJson(core.context),
    );
    final targets = await drafts.targets();
    expect(targets.map((target) => target.id), [_resourceId, _otherResourceId]);
    await expectLater(
      drafts.create('turn on'),
      throwsA(
        isA<LarenorServerException>().having(
          (e) => e.code,
          'code',
          'automation_draft_target_required',
        ),
      ),
    );
    expect(core.draftedTarget, isNull);
    final chosen = await drafts.create('turn on', resourceId: _otherResourceId);
    expect(chosen.draft.resourceId, _otherResourceId);
    expect(chosen.targetLabel, 'Other lamp');
    expect(core.draftedTarget, _otherResourceId);
    await expectLater(
      drafts.create('turn on', resourceId: 'f' * 32),
      throwsA(
        isA<LarenorServerException>().having(
          (e) => e.code,
          'code',
          'automation_draft_target_missing',
        ),
      ),
    );
    expect(core.draftedTarget, _otherResourceId);
  });

  test('F01-F03 production clients cross loopback HTTP and reject malformed envelopes', () async {
    final core = await _AutomationCore.start();
    final api = _api(core);
    addTearDown(() async {
      api.close();
      await core.close();
    });
    final context = ServerContext.fromJson(core.context);
    final draftApi = ServerAutomationDraftApi(api, _token, context);
    final selection = await draftApi.create('turn on');
    expect(selection.targetLabel, 'Reading lamp');
    expect(selection.draft.action, 'turn_on');
    expect(selection.draft.rule, isNull);

    final trialApi = ServerAutomationTrialApi(api, _token, context);
    final trial = await trialApi.create('Europe/Berlin');
    expect(trial.utcDurationSeconds, 7 * 86400 + 3600);
    final evaluated = await trialApi.evaluate(trial, 'synthetic');
    expect(evaluated.events.single.fold, 1);
    final replay = await trialApi.replay(evaluated);
    expect(replay.changedDecisionCount, 1);
    expect(replay.deterministicFingerprint, 'd' * 64);

    core
      ..malformedDraft = true
      ..malformedReplay = true;
    await expectLater(
      draftApi.create('turn on'),
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'invalid_response',
        ),
      ),
    );
    await expectLater(
      trialApi.replay(evaluated),
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'invalid_response',
        ),
      ),
    );
    expect(
      core.requests.every((request) => request.contains('/prefix/api/v1/')),
      isTrue,
    );
  });

  test('F03 controller discards a replay delivered after account authority is lost', () async {
    final core = await _AutomationCore.start();
    final store = _Store(_session(core));
    final account = ServerAccountController(
      store: store,
      clock: () => DateTime.utc(2026, 9, 30),
      apiFactory: (_) => _api(core),
    );
    addTearDown(() async {
      account.dispose();
      await core.close();
    });
    await account.initialize();
    expect(account.session?.context, isNotNull);
    final controller = ServerAutomationTrialController(account);
    addTearDown(controller.dispose);
    await controller.load(() => true);
    expect(controller.trial?.id, _trialId);

    core.replayGate = Completer<void>();
    final pending = controller.replayHistory(() => true);
    while (core.replayRequests == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final signOut = account.signOut();
    core.replayGate!.complete();
    await Future.wait([pending, signOut]);

    expect(account.session, isNull);
    expect(controller.trial, isNull);
    expect(controller.replay, isNull);
    expect(controller.announcement, isNull);
    expect(controller.busy, isFalse);
  });
}
