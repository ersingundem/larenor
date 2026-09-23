import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import 'server_media_recovery_cache.dart';
import 'server_media_recovery_api.dart';
import '../domain/server_media_recovery_models.dart';

const _recoveryCacheFallbackFailures = {
  'connection_failed',
  'timeout',
  'server_error',
  'rate_limited',
};

class ServerMediaRecoveryController extends ChangeNotifier {
  ServerMediaRecoveryController(this.account, {ServerMediaRecoveryCache? cache})
    : _accountGeneration = account.generation,
      _cache = cache ?? ServerMediaRecoveryCache() {
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final ServerMediaRecoveryCache _cache;
  final int _accountGeneration;
  int _epoch = 0;
  bool _disposed = false;
  bool busy = false;
  String? failure;
  ServerMediaRecoveryStatus? status;
  bool cached = false;

  bool get _authorized =>
      account.isCurrent(_accountGeneration) &&
      account.initialized &&
      !account.working &&
      account.session?.user.canAdminister == true;

  void _accountChanged() {
    if (!_authorized) invalidate();
  }

  void invalidate() {
    _epoch++;
    busy = false;
    failure = null;
    status = null;
    cached = false;
    if (!_disposed) notifyListeners();
  }

  bool _routeCurrent(bool Function() current) {
    try {
      return current();
    } catch (_) {
      return false;
    }
  }

  Future<void> load({required bool Function() current}) async {
    if (_disposed || busy || !_authorized || !_routeCurrent(current)) return;
    final epoch = _epoch;
    bool valid() =>
        !_disposed && epoch == _epoch && _authorized && _routeCurrent(current);
    busy = true;
    failure = null;
    ServerMediaRecoveryStatus? stored;
    notifyListeners();
    try {
      final session = account.session;
      if (session == null) return;
      final scope = ServerMediaRecoveryCacheScope.fromSession(session);
      stored = await _cache.read(scope, current: valid);
      if (!valid()) return;
      final next = await account.withSession(
        (api, session) =>
            ServerMediaRecoveryApi(api, session.accessToken).read(),
      );
      if (valid()) {
        status = next;
        cached = false;
        try {
          await _cache.write(scope, next, current: valid);
        } catch (_) {
          // Persistent cache is secondary to the authenticated live read.
        }
      }
    } catch (error) {
      if (valid()) {
        final code = error is LarenorServerException
            ? error.code
            : 'connection_failed';
        failure = code;
        if (stored != null && _recoveryCacheFallbackFailures.contains(code)) {
          status = stored;
          cached = true;
        } else {
          status = null;
          cached = false;
        }
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        final publish = valid();
        busy = false;
        if (!publish) {
          failure = null;
          status = null;
          cached = false;
        }
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    account.removeListener(_accountChanged);
    super.dispose();
  }
}
