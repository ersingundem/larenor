import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/home_workflows/data/home_workflow_api.dart';
import 'package:larenor/features/home_workflows/domain/home_workflow_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import '../../../integration_test/support/synthetic_ha_server.dart';

final _coreId = 'a' * 32;
final _homeId = 'b' * 32;
final _resourceId = '3' * 32;
final _workflowId = '6' * 32;
const _token = 'workflow_loopback_access_token';

final class _Store implements ServerSessionPersistence {
  _Store(this.value);
  ServerSession? value;
  @override
  Future<ServerSession?> read() async => value;
  @override
  Future<void> write(ServerSession? session) async => value = session;
}

final class _WorkflowCore {
  _WorkflowCore._(this.server);
  final HttpServer server;
  final requests = <String>[];
  Completer<void>? decisionGate;
  int decisionRequests = 0;

  static Future<_WorkflowCore> start() async {
    final value = _WorkflowCore._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    value.server.listen(value._handle);
    return value;
  }

  String get baseUrl => 'http://127.0.0.1:${server.port}/prefix';
  Map<String, Object?> get context => {
    'schemaVersion': 1,
    'coreId': _coreId,
    'homeId': _homeId,
  };
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
    'bindingRevision': 2,
    'resourceRevision': 1,
    'aclRevision': 1,
    'serviceRevision': 3,
    'observedAt': '2026-09-30T08:00:00Z',
    'remainingTtlMs': 5000,
    'projection': {'kind': 'switch', 'state': 'off', 'commandAvailable': true},
  };
  Map<String, Object?> workflow({required bool completed}) => {
    'schemaVersion': 1,
    'id': _workflowId,
    'revision': completed ? 2 : 1,
    'requestId': '7' * 32,
    'scope': context,
    'creatorId': '1' * 32,
    'title': 'Turn on the reading lamp',
    'target': {
      'kind': 'home_assistant_switch',
      'resource': {...context, 'kind': 'resource', 'id': _resourceId},
      'action': 'turn_on',
      'bindingRevision': 2,
      'resourceRevision': 1,
      'aclRevision': 1,
    },
    'state': completed ? 'completed' : 'waiting_decision',
    'decisionRequired': completed ? null : 'approve_effect',
    'attempt': 1,
    'stepRequestId': completed ? '8' * 32 : null,
    'effectState': completed ? 'accepted' : 'not_started',
    'reconciliationResult': completed ? 'effect_applied' : 'none',
    'cancelRequested': false,
    'deadlineAt': '2026-09-30T08:05:00Z',
    'createdAt': '2026-09-30T08:00:00Z',
    'updatedAt': completed ? '2026-09-30T08:00:01Z' : '2026-09-30T08:00:00Z',
  };

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    requests.add('${request.method} $path');
    Object? body;
    if (request.method != 'GET') {
      final text = await utf8.decoder.bind(request).join();
      if (text.isNotEmpty) body = jsonDecode(text);
    }
    if (path.endsWith('/auth/me')) return _json(request, {'user': user});
    if (path.endsWith('/context')) return _json(request, context);
    if (path.endsWith('/auth/logout')) {
      request.response.statusCode = 204;
      return request.response.close();
    }
    if (path.endsWith('/home-resources/$_coreId/$_homeId/$_resourceId')) {
      return _json(request, {'record': resource});
    }
    if (path.endsWith(
      '/home-assistant/$_coreId/$_homeId/resources/$_resourceId/snapshot',
    )) {
      return _json(request, {'snapshot': snapshot});
    }
    if (path.endsWith('/home-workflows/$_coreId/$_homeId') &&
        request.method == 'POST') {
      final json = body! as Map;
      expect(json['requestId'], '7' * 32);
      expect(json['title'], 'Turn on the reading lamp');
      expect((json['target'] as Map)['expectedBindingRevision'], 2);
      return _json(request, {
        'schemaVersion': 1,
        'workflow': workflow(completed: false),
      }, status: 201);
    }
    if (path.endsWith(
      '/home-workflows/$_coreId/$_homeId/$_workflowId/decisions',
    )) {
      decisionRequests++;
      expect((body! as Map)['decision'], 'approve');
      if (decisionGate case final gate?) await gate.future;
      return _json(request, {
        'schemaVersion': 1,
        'workflow': workflow(completed: true),
      });
    }
    request.response.statusCode = 404;
    return _json(request, {
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

LarenorServerApi _transport(_WorkflowCore core) => LarenorServerApi(
  endpoint: ServerEndpoint(core.baseUrl),
  client: IOClient(FixtureNetwork(core.server.port).createHttpClient(null)),
  timeout: const Duration(seconds: 2),
);

ServerSession _session(_WorkflowCore core) => ServerSession(
  endpoint: ServerEndpoint(core.baseUrl),
  accessToken: _token,
  refreshToken: 'workflow_loopback_refresh_token',
  expiresAt: DateTime.utc(2027),
  user: ServerUser(
    id: '1' * 32,
    username: 'admin',
    role: ServerRole.admin,
    mustChangePassword: false,
  ),
  sessionFamilyId: '9' * 32,
  context: ServerContext.fromJson(core.context),
);

void main() {
  test(
    'F05 production client creates and approves over loopback Core HTTP',
    () async {
      final core = await _WorkflowCore.start();
      final account = ServerAccountController(
        store: _Store(_session(core)),
        clock: () => DateTime.utc(2026, 9, 30),
        apiFactory: (_) => _transport(core),
      );
      addTearDown(() async {
        account.dispose();
        await core.close();
      });
      await account.initialize();
      final context = account.context!;
      final api = await HomeWorkflowAccountApi.connect(
        account: account,
        context: context,
        isCurrent: () => true,
        apiFactory: (_) => _transport(core),
      );
      addTearDown(api.close);
      final target = HomeResourceRecord.fromJson(
        core.resource,
        expectedContext: context,
      );
      final created = await api.create(
        requestId: '7' * 32,
        title: 'Turn on the reading lamp',
        deadlineSeconds: 300,
        target: target,
        action: HomeWorkflowAction.turnOn,
      );
      expect(created.state, HomeWorkflowState.waitingDecision);
      final completed = await api.decide(
        workflow: created,
        decisionId: '5' * 32,
        decision: HomeWorkflowDecision.approve,
      );
      expect(completed.state, HomeWorkflowState.completed);
      expect(
        completed.reconciliationResult,
        HomeWorkflowReconciliationResult.effectApplied,
      );
      expect(
        core.requests.where((value) => value.startsWith('POST ')).length,
        2,
      );
      expect(
        core.requests.every((value) => value.contains('/prefix/api/v1/')),
        isTrue,
      );
    },
  );

  test('F05 late decision cannot survive lost account authority', () async {
    final core = await _WorkflowCore.start();
    final account = ServerAccountController(
      store: _Store(_session(core)),
      clock: () => DateTime.utc(2026, 9, 30),
      apiFactory: (_) => _transport(core),
    );
    addTearDown(() async {
      account.dispose();
      await core.close();
    });
    await account.initialize();
    final context = account.context!;
    final api = await HomeWorkflowAccountApi.connect(
      account: account,
      context: context,
      isCurrent: () => true,
      apiFactory: (_) => _transport(core),
    );
    addTearDown(api.close);
    final target = HomeResourceRecord.fromJson(
      core.resource,
      expectedContext: context,
    );
    final created = await api.create(
      requestId: '7' * 32,
      title: 'Turn on the reading lamp',
      deadlineSeconds: 300,
      target: target,
      action: HomeWorkflowAction.turnOn,
    );
    core.decisionGate = Completer<void>();
    final pending = api.decide(
      workflow: created,
      decisionId: '5' * 32,
      decision: HomeWorkflowDecision.approve,
    );
    while (core.decisionRequests == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final signOut = account.signOut();
    core.decisionGate!.complete();
    await expectLater(
      pending,
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'authority_changed',
        ),
      ),
    );
    await signOut;
    expect(account.session, isNull);
  });
}
