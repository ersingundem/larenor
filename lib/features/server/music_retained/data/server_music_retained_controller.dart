import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../domain/server_music_retained_models.dart';
import 'server_music_retained_api.dart';
import 'server_music_retained_cache.dart';

class ServerMusicRetainedController extends ChangeNotifier {
  ServerMusicRetainedController(this.account, {ServerMusicRetainedCache? cache})
    : _accountEpoch = account.generation,
      _cache = cache ?? ServerMusicRetainedCache() {
    account.addListener(_accountChanged);
  }
  final ServerAccountController account;
  final int _accountEpoch;
  final ServerMusicRetainedCache _cache;
  int _epoch = 0;
  bool _disposed = false, busy = false;
  bool stored = false, reachable = false, verified = false;
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
    stored = false;
    reachable = false;
    verified = false;
    failure = null;
    overview = null;
    _emit();
  }

  Future<void> load({required bool Function() current}) async {
    if (_disposed || busy || !_authorized || !current()) return;
    final epoch = _epoch;
    bool valid() => !_disposed && epoch == _epoch && _authorized && current();
    busy = true;
    stored = false;
    reachable = false;
    verified = false;
    failure = null;
    overview = null;
    _emit();
    try {
      await account.withSession((api, session) async {
        final scope = ServerMusicRetainedCacheScope.fromSession(session);
        final cached = await _cache.read(scope, current: valid);
        if (!valid()) return;
        if (cached != null) {
          overview = cached;
          stored = true;
          _emit();
        }
        final value = await ServerMusicRetainedApi(
          api,
          session.accessToken,
        ).read();
        if (!valid()) return;
        overview = value;
        stored = true;
        reachable = true;
        verified = true;
        _emit();
        try {
          await _cache.write(scope, value, current: valid);
        } catch (_) {}
      });
    } catch (error) {
      if (valid()) {
        failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
        if (!stored) overview = null;
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
