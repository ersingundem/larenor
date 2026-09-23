// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../../media_catalog/data/server_media_catalog_api.dart';
import '../../media_result_origin.dart';
import '../domain/server_media_rows_models.dart';
import 'server_media_rows_api.dart';
import 'server_media_rows_cache.dart';

final class ServerMediaRowsController extends ChangeNotifier {
  ServerMediaRowsController(
    this.account, {
    ServerMediaRowsCache? cache,
    String Function()? requestId,
  }) : _accountGeneration = account.generation,
       _cache = cache ?? ServerMediaRowsCache.shared,
       _requestId = requestId {
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final int _accountGeneration;
  final ServerMediaRowsCache _cache;
  final String Function()? _requestId;
  int _epoch = 0;
  bool _disposed = false;
  ServerMediaRowsCacheScope? _activeScope;

  bool busy = false;
  String? failure;
  ServerAccountMediaRows? value;
  ServerMediaResultOrigin? origin;

  bool get _authorized =>
      account.isCurrent(_accountGeneration) &&
      account.initialized &&
      !account.working &&
      !account.hasPendingContext &&
      account.session != null &&
      account.session?.context != null &&
      account.session?.authMutationPending == false &&
      account.session?.user.mustChangePassword == false;

  void _accountChanged() {
    if (!_authorized) {
      retire();
      return;
    }
    final scope = _activeScope;
    final session = account.session;
    if (scope != null &&
        session != null &&
        ServerMediaRowsCacheScope.fromSession(session) != scope) {
      retire();
    }
  }

  void retire() {
    if (_disposed) return;
    final scope = _activeScope;
    if (scope != null) _cache.evictScope(scope);
    _activeScope = null;
    _epoch++;
    busy = false;
    failure = null;
    value = null;
    origin = null;
    notifyListeners();
  }

  Future<void> refresh({required bool Function() current}) async {
    bool routeCurrent() {
      try {
        return current();
      } catch (_) {
        return false;
      }
    }

    if (_disposed || busy || !_authorized || !routeCurrent()) return;
    final operation = ++_epoch;
    bool valid() =>
        !_disposed && operation == _epoch && _authorized && routeCurrent();
    busy = true;
    failure = null;
    notifyListeners();
    try {
      await account.withSession((api, session) async {
        bool requestCurrent() => valid() && identical(account.session, session);
        final scope = ServerMediaRowsCacheScope.fromSession(session);
        _activeScope = scope;
        final target = await ServerMediaCatalogApi(
          api,
          session.accessToken,
        ).discoverTarget(current: requestCurrent);
        if (!requestCurrent()) return;
        final cached = _cache.read(scope, target, current: requestCurrent);
        if (cached != null) {
          value = cached;
          origin = ServerMediaResultOrigin.verifiedCache;
          notifyListeners();
        }
        final fresh = await ServerMediaRowsApi(
          api,
          session.accessToken,
          requestId: _requestId,
        ).readVerifiedTarget(target: target, current: requestCurrent);
        if (!requestCurrent()) return;
        _cache.write(scope, target, fresh, current: requestCurrent);
        if (!requestCurrent()) return;
        value = fresh;
        origin = ServerMediaResultOrigin.live;
      });
    } on LarenorServerException catch (error) {
      if (valid()) {
        failure = error.code;
        if (error.code == 'media_rows_authority_changed' ||
            error.code == 'forbidden' ||
            error.code == 'unauthorized') {
          final scope = _activeScope;
          if (scope != null) _cache.evictScope(scope);
          value = null;
          origin = null;
        }
      }
    } catch (_) {
      if (valid()) failure = 'connection_failed';
    } finally {
      if (!_disposed && operation == _epoch) {
        busy = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    account.removeListener(_accountChanged);
    super.dispose();
  }
}
