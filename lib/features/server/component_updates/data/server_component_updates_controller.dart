import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../domain/server_component_update_models.dart';
import 'server_component_updates_api.dart';

final class ServerComponentUpdatesController extends ChangeNotifier {
  ServerComponentUpdatesController(this.account)
    : _accountEpoch = account.generation {
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final int _accountEpoch;
  int _epoch = 0;
  bool _disposed = false;
  bool busy = false;
  String? failure;
  ServerComponentUpdateInventory? inventory;

  bool get authorized =>
      account.isCurrent(_accountEpoch) &&
      account.initialized &&
      !account.working &&
      account.session?.user.canAdminister == true;

  void _accountChanged() {
    if (!authorized) invalidate();
  }

  void invalidate() {
    _epoch++;
    busy = false;
    failure = null;
    inventory = null;
    _emit();
  }

  Future<void> load({required bool Function() current}) async {
    if (_disposed || busy || !authorized || !current()) return;
    final epoch = _epoch;
    bool valid() => !_disposed && epoch == _epoch && authorized && current();
    busy = true;
    failure = null;
    _emit();
    try {
      final value = await account.withSession((api, session) async {
        if (!valid()) throw const LarenorServerException('cancelled');
        return ServerComponentUpdatesApi(api, session.accessToken).inventory();
      });
      if (valid()) inventory = value;
    } catch (error) {
      if (valid()) {
        failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
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
