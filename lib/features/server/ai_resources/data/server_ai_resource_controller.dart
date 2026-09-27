import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../domain/server_ai_resource_models.dart';
import 'server_ai_resource_api.dart';

final class ServerAiResourceController extends ChangeNotifier {
  ServerAiResourceController(this.account)
    : _accountEpoch = account.generation,
      _accountId = account.session?.user.id,
      _endpoint = account.session?.endpoint.baseUrl,
      _context = account.session?.context {
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final int _accountEpoch;
  final String? _accountId, _endpoint;
  final ServerContext? _context;
  int _epoch = 0;
  bool _disposed = false;
  bool busy = false, needsRefresh = false;
  String? failure, announcement;
  AiResourceSnapshot? value;

  bool get _authorized {
    final session = account.session;
    return _context != null &&
        account.isCurrent(_accountEpoch) &&
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
    busy = false;
    needsRefresh = false;
    failure = announcement = null;
    value = null;
    _emit();
  }

  Future<void> load({required bool Function() current}) =>
      _run(current, (api) => api.snapshot());

  Future<void> apply(
    AiResourcePreset preset, {
    required bool Function() current,
  }) {
    final snapshot = value;
    if (snapshot == null) return Future.value();
    return _run(
      current,
      (api) => api.updatePolicy(snapshot.policy, preset),
      mutation: true,
      success: 'policy',
    );
  }

  Future<void> cancel(AiResourceJob job, {required bool Function() current}) =>
      _run(
        current,
        (api) => api.cancel(job),
        mutation: true,
        success: 'cancelled',
      );

  Future<void> _run(
    bool Function() current,
    Future<AiResourceSnapshot> Function(ServerAiResourceApi api) action, {
    bool mutation = false,
    String? success,
  }) async {
    if (_disposed ||
        busy ||
        !_authorized ||
        !current() ||
        (mutation && needsRefresh)) {
      return;
    }
    final epoch = _epoch;
    bool valid() => !_disposed && epoch == _epoch && _authorized && current();
    busy = true;
    failure = announcement = null;
    _emit();
    try {
      final next = await account.withSession((raw, session) {
        if (!valid() ||
            session.user.id != _accountId ||
            session.endpoint.baseUrl != _endpoint ||
            session.context != _context) {
          throw const LarenorServerException('cancelled');
        }
        return action(ServerAiResourceApi(raw, session.accessToken, _context!));
      });
      if (!valid()) return;
      value = next;
      needsRefresh = false;
      announcement = success;
    } catch (error) {
      if (!valid()) return;
      failure = error is LarenorServerException
          ? error.code
          : 'connection_failed';
      if (mutation) needsRefresh = true;
      if ({
        'invalid_response',
        'unauthorized',
        'forbidden',
        'password_change_required',
      }.contains(failure)) {
        value = null;
      }
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
    account.removeListener(_accountChanged);
    super.dispose();
  }
}
