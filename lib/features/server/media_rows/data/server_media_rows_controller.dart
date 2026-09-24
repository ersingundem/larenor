// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../../media_result_origin.dart';
import '../domain/server_media_rows_models.dart';
import '../../media_catalog/domain/server_media_catalog_models.dart';
import 'server_media_rows_api.dart';
import 'server_media_rows_cache.dart';

final class ServerMediaRowsController extends ChangeNotifier {
  ServerMediaRowsController(
    this.account, {
    ServerMediaRowsCache? cache,
    String Function()? requestId,
  }) : _accountGeneration = account.generation,
       _cache = cache ?? ServerMediaRowsCache(),
       _requestId = requestId {
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final int _accountGeneration;
  final ServerMediaRowsCache _cache;
  final String Function()? _requestId;
  int _epoch = 0;
  bool _disposed = false;

  bool busy = false;
  String? failure;
  ServerAccountMediaRows? value;
  ServerMediaResultOrigin? origin;
  String? resolvingItemId;
  String? resolutionFailure;

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
  }

  void retire() {
    if (_disposed) return;
    _epoch++;
    busy = false;
    failure = null;
    value = null;
    origin = null;
    resolvingItemId = null;
    resolutionFailure = null;
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

    if (_disposed ||
        busy ||
        resolvingItemId != null ||
        !_authorized ||
        !routeCurrent()) {
      return;
    }
    final operation = ++_epoch;
    bool valid() =>
        !_disposed && operation == _epoch && _authorized && routeCurrent();
    busy = true;
    failure = null;
    value = null;
    origin = null;
    notifyListeners();
    try {
      await account.withSession((api, session) async {
        bool requestCurrent() => valid() && identical(account.session, session);
        final client = ServerMediaRowsApi(
          api,
          session.accessToken,
          requestId: _requestId,
        );
        final target = await client.discoverTarget(current: requestCurrent);
        if (!requestCurrent()) return;
        final scope = ServerMediaRowsCacheScope.fromSession(session);
        final cached = await _cache.read(
          scope,
          target,
          current: requestCurrent,
        );
        if (!requestCurrent()) return;
        if (cached != null) {
          value = cached;
          origin = ServerMediaResultOrigin.verifiedCache;
          notifyListeners();
        }
        final fresh = await client.readVerifiedTarget(
          target: target,
          current: requestCurrent,
        );
        if (!requestCurrent()) return;
        try {
          await _cache.write(scope, target, fresh, current: requestCurrent);
        } catch (_) {
          // Persistence failure cannot invalidate a fresh authority-bound read.
        }
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

  Future<ServerMediaCatalogPage?> resolve(
    ServerMediaRowItem item, {
    required bool Function() current,
  }) async {
    bool routeCurrent() {
      try {
        return current();
      } catch (_) {
        return false;
      }
    }

    final rows = value;
    if (_disposed ||
        rows == null ||
        resolvingItemId != null ||
        !_authorized ||
        !routeCurrent()) {
      return null;
    }
    final operation = ++_epoch;
    bool valid() =>
        !_disposed &&
        operation == _epoch &&
        _authorized &&
        identical(value, rows) &&
        routeCurrent();
    resolvingItemId = item.itemId;
    resolutionFailure = null;
    notifyListeners();
    ServerMediaCatalogPage? resolved;
    try {
      await account.withSession((api, session) async {
        bool requestCurrent() => valid() && identical(account.session, session);
        resolved = await ServerMediaRowsApi(
          api,
          session.accessToken,
          requestId: _requestId,
        ).resolveVerifiedRow(rows: rows, item: item, current: requestCurrent);
        if (!requestCurrent()) resolved = null;
      });
    } on LarenorServerException catch (error) {
      if (valid()) resolutionFailure = error.code;
    } catch (_) {
      if (valid()) resolutionFailure = 'connection_failed';
    } finally {
      if (!_disposed && operation == _epoch) {
        resolvingItemId = null;
        notifyListeners();
      }
    }
    return valid() ? resolved : null;
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
