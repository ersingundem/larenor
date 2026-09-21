import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import 'server_media_recovery_api.dart';
import '../domain/server_media_recovery_models.dart';

class ServerMediaRecoveryController extends ChangeNotifier {
  ServerMediaRecoveryController(this.account)
    : _accountGeneration = account.generation {
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final int _accountGeneration;
  int _epoch = 0;
  bool _disposed = false;
  bool busy = false;
  String? failure;
  ServerMediaRecoveryStatus? status;

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
    notifyListeners();
    try {
      final next = await account.withSession(
        (api, session) =>
            ServerMediaRecoveryApi(api, session.accessToken).read(),
      );
      if (valid()) status = next;
    } catch (error) {
      if (valid()) {
        failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
        status = null;
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        final publish = valid();
        busy = false;
        if (!publish) {
          failure = null;
          status = null;
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
