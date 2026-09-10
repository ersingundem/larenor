import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../domain/server_music_retained_models.dart';
import 'server_music_retained_api.dart';

class ServerMusicRetainedController extends ChangeNotifier {
  ServerMusicRetainedController(this.account)
    : _accountEpoch = account.generation {
    account.addListener(_accountChanged);
  }
  final ServerAccountController account;
  final int _accountEpoch;
  int _epoch = 0;
  bool _disposed = false, busy = false;
  String? failure;
  ServerMusicRetainedOverview? overview;

  bool get _authorized =>
      account.isCurrent(_accountEpoch) &&
      account.initialized &&
      !account.working &&
      account.session?.user.canAdminister == true;

  void _accountChanged() {
    if (!_authorized) invalidate();
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void invalidate() {
    _epoch++;
    busy = false;
    failure = null;
    overview = null;
    _emit();
  }

  Future<void> load({required bool Function() current}) async {
    if (_disposed || busy || !_authorized || !current()) return;
    final epoch = _epoch;
    bool valid() => !_disposed && epoch == _epoch && _authorized && current();
    busy = true;
    failure = null;
    _emit();
    try {
      await account.withSession((api, session) async {
        final value = await ServerMusicRetainedApi(
          api,
          session.accessToken,
        ).read();
        if (valid()) overview = value;
      });
    } catch (error) {
      if (valid()) {
        failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
        overview = null;
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        busy = false;
        _emit();
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
