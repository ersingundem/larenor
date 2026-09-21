import 'dart:async';

import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/shared_expense_models.dart';

final class SharedExpenseAccountApi implements SharedExpenseApi {
  SharedExpenseAccountApi._({
    required this.account,
    required this.context,
    required this.routeId,
    required this.isCurrent,
    required this.authority,
    required this._generation,
    required this._endpoint,
    required this._api,
  });

  static Future<SharedExpenseAccountApi> connect({
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
      final json = _object(
        await api.request(
          'GET',
          '/shared-expenses/${context.coreId}/${context.homeId}',
          token: session.accessToken,
        ),
      );
      if (!isCurrent() || !account.isCurrent(generation)) {
        throw const LarenorServerException('authority_changed');
      }
      final authority = SharedExpenseAuthority.fromJson(
        _object(json['authority']),
        routeId: routeId,
        coreId: context.coreId,
        homeId: context.homeId,
        accountId: session.user.id,
      );
      return SharedExpenseAccountApi._(
        account: account,
        context: context,
        routeId: routeId,
        isCurrent: isCurrent,
        authority: authority,
        generation: generation,
        endpoint: captured.endpoint,
        api: api,
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
  final SharedExpenseAuthority authority;
  final int _generation;
  final ServerEndpoint _endpoint;
  final LarenorServerApi _api;
  bool _closed = false;

  String get _root => '/shared-expenses/${context.coreId}/${context.homeId}';

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

  SharedExpenseAuthority _authority(Map<String, dynamic> json) {
    final value = SharedExpenseAuthority.fromJson(
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
  Future<ExpenseLedgerSnapshot> snapshot(
    SharedExpenseAuthority expected,
  ) async {
    if (expected != authority) throw const FormatException('authority_changed');
    final json = _object(await _request('GET', _root));
    if (json.length != 4 ||
        json['ledgerRevision'] is! int ||
        json['participants'] is! List ||
        json['records'] is! List) {
      throw const FormatException('invalid_response');
    }
    final responseAuthority = _authority(json);
    final revision = json['ledgerRevision'] as int;
    if (revision < 1) throw const FormatException('invalid_response');
    return ExpenseLedgerSnapshot(
      authority: responseAuthority,
      ledgerRevision: revision,
      membersRevision: responseAuthority.membersRevision,
      participants: (json['participants'] as List)
          .map((value) => ExpenseParticipant.fromJson(_object(value)))
          .toList(growable: false),
      records: (json['records'] as List)
          .map((value) => SharedExpenseRecord.fromJson(_object(value)))
          .toList(growable: false),
    );
  }

  @override
  Future<SharedExpenseReceipt> create(
    SharedExpenseAuthority expected, {
    required int expectedLedgerRevision,
    required int expectedMembersRevision,
    required String commandId,
    required ExpenseDraft draft,
  }) async {
    if (expected != authority ||
        expectedMembersRevision != authority.membersRevision) {
      throw const FormatException('authority_changed');
    }
    final json = _object(
      await _request(
        'POST',
        '$_root/commands/create',
        body: {
          'schemaVersion': 1,
          'commandId': commandId,
          'expectedLedgerRevision': expectedLedgerRevision,
          'expectedMembersRevision': expectedMembersRevision,
          'title': draft.title,
          'currency': draft.currency,
          'totalMinor': draft.totalMinor,
          'payerId': draft.payerId,
          'participantIds': draft.shares
              .map((value) => value.accountId)
              .toList(),
        },
      ),
    );
    return _receipt(json);
  }

  @override
  Future<SharedExpenseReceipt?> receipt(
    SharedExpenseAuthority expected,
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

  SharedExpenseReceipt _receipt(Map<String, dynamic> json) {
    if (json.length != 5 ||
        !_id(json['eventId']) ||
        !_id(json['commandId']) ||
        json['ledgerRevision'] is! int ||
        (json['ledgerRevision'] as int) < 2) {
      throw const FormatException('invalid_receipt');
    }
    return SharedExpenseReceipt(
      authority: _authority(json),
      eventId: json['eventId'] as String,
      commandId: json['commandId'] as String,
      ledgerRevision: json['ledgerRevision'] as int,
      record: SharedExpenseRecord.fromJson(_object(json['record'])),
    );
  }

  @override
  Future<ExpenseExport> export(
    SharedExpenseAuthority expected, {
    required int ledgerRevision,
  }) async {
    if (expected != authority) throw const FormatException('authority_changed');
    final json = _object(
      await _request(
        'POST',
        '$_root/export',
        body: {'schemaVersion': 1, 'expectedLedgerRevision': ledgerRevision},
      ),
    );
    if (json.length != 3 ||
        json['ledgerRevision'] != ledgerRevision ||
        json['records'] is! List) {
      throw const FormatException('invalid_export');
    }
    return ExpenseExport(
      _authority(json),
      ledgerRevision,
      (json['records'] as List)
          .map((value) => SharedExpenseRecord.fromJson(_object(value)))
          .toList(growable: false),
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

bool _id(Object? value) =>
    value is String &&
    value.length == 32 &&
    RegExp(r'^[0-9a-f]{32}$').hasMatch(value);
