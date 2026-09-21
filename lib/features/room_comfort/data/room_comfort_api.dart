import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/room_comfort_models.dart';

final class RoomComfortApi implements RoomComfortGateway {
  RoomComfortApi(this._api, this._session, {required bool Function() isCurrent})
    : _current = isCurrent;

  final LarenorServerApi _api;
  final ServerSession _session;
  final bool Function() _current;
  bool _retired = false;
  ServerContext get _context => _session.context!;
  String get _root => '/room-comfort/${_context.coreId}/${_context.homeId}';

  void _check() {
    if (!_retired &&
        _session.context != null &&
        _session.user.canAdminister &&
        _current()) {
      return;
    }
    _retired = true;
    throw const LarenorServerException('cancelled');
  }

  Future<T> _run<T>(Future<T> Function() action) async {
    _check();
    try {
      final result = await action();
      _check();
      return result;
    } catch (_) {
      _check();
      rethrow;
    }
  }

  @override
  Future<RoomComfortPlan> loadPlan() => _run(() async {
    final body = serverObject(
      await _api.request('GET', '$_root/plan', token: _session.accessToken),
    );
    if (body.length != 2 || body['schemaVersion'] != 1) {
      throw const LarenorServerException('invalid_response');
    }
    try {
      return RoomComfortPlan.fromJson(
        body['plan'],
        coreId: _context.coreId,
        homeId: _context.homeId,
        accountId: _session.user.id,
      );
    } on FormatException {
      throw const LarenorServerException('invalid_response');
    }
  });

  @override
  Future<RoomComfortPreview> preview(RoomComfortPlan plan, String requestId) =>
      _run(() async {
        final body = serverObject(
          await _api.request(
            'POST',
            '$_root/previews',
            token: _session.accessToken,
            body: {
              'schemaVersion': 1,
              'requestId': requestId,
              'expectedPlanId': plan.planId,
              'expectedHomeRevision': plan.homeRevision,
              'expectedPolicyRevision': plan.policyRevision,
            },
          ),
        );
        if (body.length != 2 || body['schemaVersion'] != 1) {
          throw const LarenorServerException('invalid_response');
        }
        final value = serverObject(body['preview']);
        if (value.length != 7 ||
            value['schemaVersion'] != 1 ||
            value['planId'] != plan.planId ||
            value['requestId'] != requestId) {
          throw const LarenorServerException('invalid_response');
        }
        final expires = value['expiresAtMs'], count = value['commandCount'];
        final id = value['previewId'], token = value['confirmToken'];
        if (id is! String ||
            !RegExp(r'^[0-9a-f]{32}$').hasMatch(id) ||
            token is! String ||
            !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token) ||
            expires is! int ||
            expires < 1 ||
            count is! int ||
            count < 1 ||
            count > 64) {
          throw const LarenorServerException('invalid_response');
        }
        return RoomComfortPreview(
          id: id,
          planId: plan.planId,
          policyRevision: plan.policyRevision,
          token: token,
          expiresAt: DateTime.fromMillisecondsSinceEpoch(expires, isUtc: true),
          commandCount: count,
        );
      });

  @override
  Future<RoomComfortReceipt> confirm(RoomComfortPreview preview) => _run(
    () async {
      final body = serverObject(
        await _api.request(
          'POST',
          '$_root/previews/${preview.id}/confirm',
          token: _session.accessToken,
          body: {
            'schemaVersion': 1,
            'expectedPlanId': preview.planId,
            'expectedPolicyRevision': preview.policyRevision,
            'confirmToken': preview.token,
          },
        ),
      );
      if (body.length != 2 || body['schemaVersion'] != 1) {
        throw const LarenorServerException('invalid_response');
      }
      final value = serverObject(body['receipt']);
      if (value.length != 6 ||
          value['schemaVersion'] != 1 ||
          value['planId'] != preview.planId) {
        throw const LarenorServerException('invalid_response');
      }
      final requestId = value['requestId'],
          status = value['status'],
          results = value['results'];
      if (requestId is! String ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId) ||
          !const {'applied', 'partial', 'failed', 'unknown'}.contains(status) ||
          results is! List ||
          results.isEmpty ||
          results.length > 64 ||
          !_validResults(results)) {
        throw const LarenorServerException('invalid_response');
      }
      return RoomComfortReceipt(
        requestId: requestId,
        planId: preview.planId,
        status: status as String,
        commandCount: results.length,
      );
    },
  );

  bool _validResults(List<Object?> results) {
    for (final raw in results) {
      final value = serverObject(raw);
      if (value.length != 7 || value['schemaVersion'] != 1) return false;
      final commandId = value['commandId'];
      final roomId = value['roomId'];
      final kind = value['targetKind'];
      final status = value['status'];
      final code = value['code'];
      if (commandId is! String ||
          roomId is! String ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(commandId) ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(roomId) ||
          !const {'hvac', 'window'}.contains(kind) ||
          !const {
            ('applied', 'applied'),
            ('failed', 'readback_mismatch'),
            ('unknown', 'worker_ack_unknown'),
          }.contains((status, code))) {
        return false;
      }
      if (status == 'unknown' && value['readback'] != null) return false;
    }
    return true;
  }

  @override
  void retire() => _retired = true;
}

final class AccountRoomComfortGateway implements RoomComfortGateway {
  AccountRoomComfortGateway({
    required ServerAccountController account,
    required bool Function() isCurrent,
  }) : _account = account,
       _current = isCurrent,
       _generation = account.generation,
       _session = account.session,
       _context = account.session?.context;
  final ServerAccountController _account;
  final bool Function() _current;
  final int _generation;
  final ServerSession? _session;
  final ServerContext? _context;
  bool _retired = false;
  bool _valid() =>
      !_retired &&
      _account.isCurrent(_generation) &&
      identical(_account.session, _session) &&
      _account.session?.context == _context &&
      _account.session?.user.canAdminister == true &&
      _current();
  Future<T> _run<T>(Future<T> Function(RoomComfortApi) operation) async {
    if (!_valid()) throw const LarenorServerException('cancelled');
    return _account.withSession((api, session) async {
      if (!_valid() || !identical(session, _session)) {
        throw const LarenorServerException('cancelled');
      }
      final gateway = RoomComfortApi(api, session, isCurrent: _valid);
      try {
        return await operation(gateway);
      } finally {
        gateway.retire();
      }
    });
  }

  @override
  Future<RoomComfortPlan> loadPlan() => _run((api) => api.loadPlan());
  @override
  Future<RoomComfortPreview> preview(RoomComfortPlan plan, String requestId) =>
      _run((api) => api.preview(plan, requestId));
  @override
  Future<RoomComfortReceipt> confirm(RoomComfortPreview preview) =>
      _run((api) => api.confirm(preview));
  @override
  void retire() => _retired = true;
}
