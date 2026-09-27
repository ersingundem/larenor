import 'dart:async';

import '../../core_ha/data/core_ha_api.dart';
import '../../home_resources/domain/home_resource_models.dart';
import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/home_workflow_models.dart';

abstract interface class HomeWorkflowApi {
  Future<HomeWorkflowPage> list({String? before, int limit = 50});

  Future<HomeWorkflow> detail(String workflowId);

  Future<HomeWorkflow> create({
    required String requestId,
    required String title,
    required int deadlineSeconds,
    required HomeResourceRecord target,
    required HomeWorkflowAction action,
  });

  Future<HomeWorkflow> decide({
    required HomeWorkflow workflow,
    required String decisionId,
    required HomeWorkflowDecision decision,
  });

  Future<HomeWorkflow> resume({
    required HomeWorkflow workflow,
    required String resumeId,
  });
}

final class HomeWorkflowAccountApi implements HomeWorkflowApi {
  HomeWorkflowAccountApi._({
    required this.account,
    required this.context,
    required this.isCurrent,
    required int generation,
    required ServerEndpoint endpoint,
    required String accountId,
    required LarenorServerApi api,
  }) : _generation = generation,
       _endpoint = endpoint,
       _accountId = accountId,
       _api = api;

  static Future<HomeWorkflowAccountApi> connect({
    required ServerAccountController account,
    required ServerContext context,
    required bool Function() isCurrent,
    ServerApiFactory? apiFactory,
  }) async {
    final generation = account.generation;
    final captured = account.session;
    if (captured == null ||
        captured.context != context ||
        captured.user.mustChangePassword ||
        !isCurrent()) {
      throw const LarenorServerException('authority_changed');
    }
    final api = (apiFactory ?? ((value) => LarenorServerApi(endpoint: value)))(
      captured.endpoint,
    );
    try {
      final session = await account.ensureSession();
      if (!isCurrent() ||
          !account.isCurrent(generation) ||
          session.context != context ||
          session.endpoint.baseUrl != captured.endpoint.baseUrl ||
          session.user.id != captured.user.id) {
        throw const LarenorServerException('authority_changed');
      }
      return HomeWorkflowAccountApi._(
        account: account,
        context: context,
        isCurrent: isCurrent,
        generation: generation,
        endpoint: captured.endpoint,
        accountId: captured.user.id,
        api: api,
      );
    } catch (_) {
      api.close();
      rethrow;
    }
  }

  final ServerAccountController account;
  final ServerContext context;
  final bool Function() isCurrent;
  final int _generation;
  final ServerEndpoint _endpoint;
  final String _accountId;
  final LarenorServerApi _api;
  bool _closed = false;

  String get _root => '/home-workflows/${context.coreId}/${context.homeId}';

  bool get _valid {
    try {
      final session = account.session;
      return !_closed &&
          isCurrent() &&
          account.isCurrent(_generation) &&
          session != null &&
          session.context == context &&
          session.endpoint.baseUrl == _endpoint.baseUrl &&
          session.user.id == _accountId &&
          !session.user.mustChangePassword;
    } catch (_) {
      return false;
    }
  }

  Future<ServerSession> _session() async {
    if (!_valid) throw const LarenorServerException('authority_changed');
    final session = await account.ensureSession();
    if (!_valid ||
        session.context != context ||
        session.endpoint.baseUrl != _endpoint.baseUrl ||
        session.user.id != _accountId) {
      throw const LarenorServerException('authority_changed');
    }
    return session;
  }

  Future<T> _operation<T>(
    Future<T> Function(ServerSession session) action,
  ) async {
    try {
      final session = await _session();
      final result = await action(session);
      await _session();
      return result;
    } on LarenorServerException catch (error) {
      if ({
        'connection_failed',
        'timeout',
        'server_unavailable',
        'server_error',
      }.contains(error.code)) {
        throw TimeoutException(error.code);
      }
      rethrow;
    }
  }

  Map<Object?, Object?> _object(Object? raw, Set<String> keys) {
    if (raw is! Map ||
        raw.length != keys.length ||
        !keys.every(raw.containsKey)) {
      throw const LarenorServerException('invalid_response');
    }
    return raw;
  }

  HomeWorkflow _workflow(Object? raw) {
    final envelope = _object(raw, {'schemaVersion', 'workflow'});
    if (envelope['schemaVersion'] != 1) {
      throw const LarenorServerException('invalid_response');
    }
    return HomeWorkflow.fromJson(
      envelope['workflow'],
      expectedContext: context,
    );
  }

  bool _identity(String value) =>
      value.length == 32 && RegExp(r'^[0-9a-f]{32}$').hasMatch(value);

  @override
  Future<HomeWorkflowPage> list({String? before, int limit = 50}) =>
      _operation((session) async {
        if (limit < 1 ||
            limit > HomeWorkflow.maximumPageSize ||
            before != null && !_identity(before)) {
          throw const LarenorServerException('invalid_request');
        }
        final raw = await _api.request(
          'GET',
          _root,
          token: session.accessToken,
          queryParameters: {'before': ?before, 'limit': '$limit'},
        );
        return HomeWorkflowPage.fromJson(
          raw,
          expectedContext: context,
          limit: limit,
        );
      });

  @override
  Future<HomeWorkflow> detail(String workflowId) => _operation((session) async {
    if (!_identity(workflowId)) {
      throw const LarenorServerException('invalid_request');
    }
    final workflow = _workflow(
      await _api.request(
        'GET',
        '$_root/$workflowId',
        token: session.accessToken,
      ),
    );
    if (workflow.id != workflowId) {
      throw const LarenorServerException('invalid_response');
    }
    return workflow;
  });

  @override
  Future<HomeWorkflow> create({
    required String requestId,
    required String title,
    required int deadlineSeconds,
    required HomeResourceRecord target,
    required HomeWorkflowAction action,
  }) => _operation((session) async {
    final normalizedTitle = title.trim();
    if (!_identity(requestId) ||
        target.context != context ||
        target.kind != HomeResourceKind.resource ||
        !target.canWrite ||
        normalizedTitle.isEmpty ||
        normalizedTitle.runes.length > HomeWorkflow.maximumTitleCharacters ||
        normalizedTitle.runes.any((rune) => rune < 32 || rune == 127) ||
        deadlineSeconds < 1 ||
        deadlineSeconds > 86400) {
      throw const LarenorServerException('invalid_request');
    }

    final first = CoreHaApi(
      _api,
      session.accessToken,
      target,
      isCurrent: () => _valid,
    );
    final fresh = await first.resource();
    if (!fresh.canWrite) {
      throw const LarenorServerException('forbidden');
    }
    final second = CoreHaApi(
      _api,
      session.accessToken,
      fresh,
      isCurrent: () => _valid,
    );
    final snapshot = await second.snapshot();
    if (snapshot.projection.kind != 'switch' ||
        !snapshot.projection.commandAvailable) {
      throw const LarenorServerException('invalid_request');
    }
    final workflow = _workflow(
      await _api.request(
        'POST',
        _root,
        token: session.accessToken,
        body: {
          'schemaVersion': 1,
          'requestId': requestId,
          'title': normalizedTitle,
          'deadlineSeconds': deadlineSeconds,
          'target': {
            'kind': 'home_assistant_switch',
            'resourceId': fresh.id,
            'action': action.wire,
            'expectedBindingRevision': snapshot.bindingRevision,
            'expectedResourceRevision': snapshot.resourceRevision,
            'expectedAclRevision': snapshot.aclRevision,
          },
        },
      ),
    );
    if (workflow.requestId != requestId ||
        workflow.title != normalizedTitle ||
        workflow.target.resourceId != fresh.id ||
        workflow.target.action != action ||
        workflow.target.bindingRevision != snapshot.bindingRevision ||
        workflow.target.resourceRevision != snapshot.resourceRevision ||
        workflow.target.aclRevision != snapshot.aclRevision) {
      throw const LarenorServerException('invalid_response');
    }
    return workflow;
  });

  @override
  Future<HomeWorkflow> decide({
    required HomeWorkflow workflow,
    required String decisionId,
    required HomeWorkflowDecision decision,
  }) => _operation((session) async {
    if (workflow.context != context || !_identity(decisionId)) {
      throw const LarenorServerException('invalid_request');
    }
    final result = _workflow(
      await _api.request(
        'POST',
        '$_root/${workflow.id}/decisions',
        token: session.accessToken,
        body: {
          'schemaVersion': 1,
          'decisionId': decisionId,
          'expectedRevision': workflow.revision,
          'decision': decision.wire,
        },
      ),
    );
    if (result.id != workflow.id || result.revision < workflow.revision) {
      throw const LarenorServerException('invalid_response');
    }
    return result;
  });

  @override
  Future<HomeWorkflow> resume({
    required HomeWorkflow workflow,
    required String resumeId,
  }) => _operation((session) async {
    if (workflow.context != context || !_identity(resumeId)) {
      throw const LarenorServerException('invalid_request');
    }
    final result = _workflow(
      await _api.request(
        'POST',
        '$_root/${workflow.id}/resume',
        token: session.accessToken,
        body: {
          'schemaVersion': 1,
          'resumeId': resumeId,
          'expectedRevision': workflow.revision,
        },
      ),
    );
    if (result.id != workflow.id || result.revision < workflow.revision) {
      throw const LarenorServerException('invalid_response');
    }
    return result;
  });

  void close() {
    if (_closed) return;
    _closed = true;
    _api.close();
  }
}
