import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../domain/server_support_session_models.dart';
import 'server_support_sessions_api.dart';

final class ServerSupportSessionsController extends ChangeNotifier {
  ServerSupportSessionsController(this.account)
    : _generation = account.generation,
      _accountId = account.session?.user.id,
      _endpoint = account.session?.endpoint.baseUrl,
      _context = account.session?.context {
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final int _generation;
  final String? _accountId, _endpoint;
  final ServerContext? _context;
  int _epoch = 0;
  bool _disposed = false, busy = false, needsRefresh = false;
  String? failure, announcement, _issuedToken;
  List<ServerSupportSession> sessions = const [];
  ServerSupportDetail? detail;

  bool get _authorized {
    final session = account.session;
    return _context != null &&
        account.isCurrent(_generation) &&
        account.initialized &&
        !account.working &&
        session?.user.canAdminister == true &&
        session?.user.id == _accountId &&
        session?.endpoint.baseUrl == _endpoint &&
        session?.context == _context;
  }

  void _accountChanged() {
    if (!_authorized) invalidate();
  }

  void invalidate() {
    _epoch++;
    busy = needsRefresh = false;
    failure = announcement = _issuedToken = null;
    sessions = const [];
    detail = null;
    _emit();
  }

  String? takeIssuedToken() {
    final value = _issuedToken;
    _issuedToken = null;
    return value;
  }

  Future<void> load(bool Function() current) => _run(current, (api) async {
    sessions = await api.list();
  });

  Future<void> loadDetail(
    ServerSupportSession session,
    bool Function() current,
  ) {
    detail = null;
    return _run(current, (api) async {
      detail = await api.detail(session);
    });
  }

  Future<void> create({
    required String supporterId,
    required String supporterName,
    required List<String> permissions,
    required bool Function() current,
  }) => _run(current, (api) async {
    final issued = await api.create(
      supporterId: supporterId,
      supporterName: supporterName,
      permissions: permissions,
    );
    sessions = List.unmodifiable([issued.session, ...sessions]);
    _issuedToken = issued.accessToken;
    announcement = 'created';
  });

  Future<void> revoke(ServerSupportSession session, bool Function() current) =>
      _run(current, (api) async {
        final revoked = await api.revoke(session);
        sessions = List.unmodifiable([
          for (final value in sessions)
            if (value.id == revoked.id) revoked else value,
        ]);
        if (detail?.session.id == revoked.id) detail = null;
        announcement = 'revoked';
      });

  Future<void> _run(
    bool Function() current,
    Future<void> Function(ServerSupportSessionsApi) action,
  ) async {
    if (_disposed || busy || !_authorized || !current() || needsRefresh) return;
    final epoch = _epoch;
    bool valid() => !_disposed && epoch == _epoch && _authorized && current();
    busy = true;
    failure = announcement = null;
    _emit();
    try {
      await account.withSession((raw, session) async {
        if (!valid()) throw const LarenorServerException('cancelled');
        await action(
          ServerSupportSessionsApi(raw, session.accessToken, _context!),
        );
      });
    } catch (error) {
      if (!valid()) return;
      _issuedToken = null;
      detail = null;
      failure = error is LarenorServerException
          ? error.code
          : 'connection_failed';
      needsRefresh = {
        'connection_failed',
        'timeout',
        'server_error',
        'invalid_response',
      }.contains(failure);
    } finally {
      if (!_disposed && epoch == _epoch) {
        busy = false;
        _emit();
      }
    }
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _issuedToken = null;
    account.removeListener(_accountChanged);
    super.dispose();
  }
}
