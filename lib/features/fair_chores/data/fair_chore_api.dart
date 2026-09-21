import 'dart:async';

import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/fair_chore_models.dart';

final class FairChoreAccountApi implements FairChoreApi {
  FairChoreAccountApi._({
    required this.account,
    required this.context,
    required this.routeId,
    required this.isCurrent,
    required this._generation,
    required this._endpoint,
    required this._api,
    required this.authority,
  });

  static Future<FairChoreAccountApi> connect({
    required ServerAccountController account,
    required ServerContext context,
    required String routeId,
    required bool Function() isCurrent,
    ServerApiFactory? apiFactory,
  }) async {
    final generation = account.generation;
    final captured = account.session;
    if (captured == null || captured.context != context || !isCurrent()) {
      throw const LarenorServerException('authority_changed');
    }
    final api = (apiFactory ?? ((value) => LarenorServerApi(endpoint: value)))(
      captured.endpoint,
    );
    try {
      final session = await account.ensureSession();
      final json = await api.request(
        'GET',
        '/fair-chores/${context.coreId}/${context.homeId}',
        token: session.accessToken,
      );
      if (!isCurrent() || !account.isCurrent(generation)) {
        throw const LarenorServerException('authority_changed');
      }
      final authority = FairChoreAuthority.fromJson(
        _object(json)['authority'] as Map<String, dynamic>,
        routeId: routeId,
        coreId: context.coreId,
        homeId: context.homeId,
        accountId: session.user.id,
      );
      return FairChoreAccountApi._(
        account: account,
        context: context,
        routeId: routeId,
        isCurrent: isCurrent,
        generation: generation,
        endpoint: captured.endpoint,
        api: api,
        authority: authority,
      );
    } catch (_) {
      api.close();
      rethrow;
    }
  }

  final ServerAccountController account;
  final ServerContext context;
  final String routeId;
  final bool Function() isCurrent;
  final int _generation;
  final ServerEndpoint _endpoint;
  final LarenorServerApi _api;
  final FairChoreAuthority authority;
  bool _closed = false;

  String get _root => '/fair-chores/${context.coreId}/${context.homeId}';

  Future<ServerSession> _session() async {
    if (_closed || !isCurrent() || !account.isCurrent(_generation)) {
      throw const LarenorServerException('authority_changed');
    }
    final session = await account.ensureSession();
    if (_closed ||
        !isCurrent() ||
        !account.isCurrent(_generation) ||
        session.context != context ||
        session.endpoint.baseUrl != _endpoint.baseUrl ||
        session.user.id != authority.accountId) {
      throw const LarenorServerException('authority_changed');
    }
    return session;
  }

  Future<Map<String, dynamic>?> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool allowEmpty = false,
  }) async {
    try {
      final session = await _session();
      final value = await _api.request(
        method,
        path,
        token: session.accessToken,
        body: body,
        allowEmpty: allowEmpty,
      );
      await _session();
      return value;
    } on LarenorServerException catch (error) {
      if ({
        'connection_failed',
        'timeout',
        'server_unavailable',
      }.contains(error.code)) {
        throw TimeoutException(error.code);
      }
      rethrow;
    }
  }

  FairChoreAuthority _authority(Map<String, dynamic> json) {
    final value = FairChoreAuthority.fromJson(
      _object(json['authority']),
      routeId: routeId,
      coreId: context.coreId,
      homeId: context.homeId,
      accountId: authority.accountId,
    );
    if (value != authority) throw const FormatException('authority_changed');
    return value;
  }

  @override
  Future<FairChorePage> list(FairChoreAuthority expected) async {
    if (expected != authority) throw const FormatException('authority_changed');
    final json = _object(await _request('GET', _root));
    if (json.length != 3 ||
        json['tasks'] is! List ||
        json['members'] is! List) {
      throw const FormatException('invalid_response');
    }
    final responseAuthority = _authority(json);
    final tasks = (json['tasks'] as List)
        .map((value) => FairChoreTask.fromJson(_object(value)))
        .toList(growable: false);
    return FairChorePage(responseAuthority, tasks);
  }

  @override
  Future<FairChoreReceipt> complete(
    FairChoreAuthority expected, {
    required String taskId,
    required int expectedRevision,
    required String commandId,
  }) => _mutate(
    expected,
    taskId: taskId,
    expectedRevision: expectedRevision,
    commandId: commandId,
    action: FairChoreAction.completed,
  );

  @override
  Future<FairChoreReceipt> defer(
    FairChoreAuthority expected, {
    required String taskId,
    required int expectedRevision,
    required String commandId,
    required int days,
  }) => _mutate(
    expected,
    taskId: taskId,
    expectedRevision: expectedRevision,
    commandId: commandId,
    action: FairChoreAction.deferred,
    days: days,
  );

  Future<FairChoreReceipt> _mutate(
    FairChoreAuthority expected, {
    required String taskId,
    required int expectedRevision,
    required String commandId,
    required FairChoreAction action,
    int days = 1,
  }) async {
    if (expected != authority) throw const FormatException('authority_changed');
    final suffix = action == FairChoreAction.completed ? 'complete' : 'defer';
    final json = _object(
      await _request(
        'POST',
        '$_root/$taskId/commands/$suffix',
        body: {
          'schemaVersion': 1,
          'commandId': commandId,
          'expectedRevision': expectedRevision,
          if (action == FairChoreAction.completed)
            'completedAt': DateTime.now().toUtc().millisecondsSinceEpoch / 1000
          else
            'days': days,
        },
      ),
    );
    return _receipt(json);
  }

  @override
  Future<FairChoreReceipt?> receipt(
    FairChoreAuthority expected,
    String commandId,
  ) async {
    if (expected != authority) throw const FormatException('authority_changed');
    final json = await _request(
      'GET',
      '$_root/receipts/$commandId',
      allowEmpty: true,
    );
    return json == null ? null : _receipt(_object(json));
  }

  FairChoreReceipt _receipt(Map<String, dynamic> json) {
    if (json.length != 5) throw const FormatException('invalid_receipt');
    final eventId = json['eventId'];
    final commandId = json['commandId'];
    final action = switch (json['action']) {
      'completed' => FairChoreAction.completed,
      'deferred' => FairChoreAction.deferred,
      _ => throw const FormatException('invalid_receipt'),
    };
    if (!_identity(eventId) || !_identity(commandId)) {
      throw const FormatException('invalid_receipt');
    }
    return FairChoreReceipt(
      authority: _authority(json),
      eventId: eventId as String,
      commandId: commandId as String,
      action: action,
      task: FairChoreTask.fromJson(_object(json['task'])),
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _api.close();
  }
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('invalid_response');
  }
  return value;
}

bool _identity(Object? value) =>
    value is String &&
    value.length == 32 &&
    RegExp(r'^[0-9a-f]{32}$').hasMatch(value);
