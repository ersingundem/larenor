// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../../media_result_origin.dart';
import '../domain/server_media_catalog_models.dart';
import 'server_media_catalog_api.dart';
import 'server_media_catalog_cache.dart';

/// Owns one explicit Core catalog search. No direct Jellyfin fallback exists.
final class ServerMediaCatalogController extends ChangeNotifier {
  ServerMediaCatalogController(
    this.account, {
    ServerMediaCatalogCache? cache,
    String Function()? requestId,
  }) : _accountGeneration = account.generation,
       _cache = cache ?? ServerMediaCatalogCache(),
       _requestId = requestId {
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final int _accountGeneration;
  final ServerMediaCatalogCache _cache;
  final String Function()? _requestId;
  int _epoch = 0;
  bool _disposed = false;

  bool busy = false;
  String? failure;
  ServerMediaCatalogPage? page;
  ServerMediaResultOrigin? origin;

  bool get _authorized =>
      account.isCurrent(_accountGeneration) &&
      account.initialized &&
      !account.working &&
      !account.hasPendingContext &&
      account.session != null &&
      account.session?.authMutationPending == false &&
      account.session?.user.mustChangePassword == false;

  void _accountChanged() {
    if (!_authorized) retire();
  }

  void retire() {
    if (_disposed) return;
    _epoch++;
    busy = false;
    failure = null;
    page = null;
    origin = null;
    notifyListeners();
  }

  Future<void> search({
    required String installationId,
    required int expectedInstallationRevision,
    required String query,
    ServerMediaCatalogKind? mediaKind,
    int offset = 0,
    int limit = 24,
    required bool Function() current,
  }) => _search(
    (api, requestCurrent) => api.search(
      installationId: installationId,
      expectedInstallationRevision: expectedInstallationRevision,
      query: query,
      mediaKind: mediaKind,
      offset: offset,
      limit: limit,
      current: requestCurrent,
    ),
    current: current,
  );

  Future<void> searchCurrent({
    required String query,
    ServerMediaCatalogKind? mediaKind,
    int offset = 0,
    int limit = 24,
    required bool Function() current,
  }) {
    final previousPage = offset == 0 ? null : page;
    return _catalogCurrent(
      operation: ServerMediaCatalogOperation.search,
      query: query,
      mediaKind: mediaKind,
      offset: offset,
      limit: limit,
      previousPage: previousPage,
      current: current,
    );
  }

  Future<void> browseCurrent({
    ServerMediaCatalogKind? mediaKind,
    int offset = 0,
    int limit = 24,
    required bool Function() current,
  }) {
    final previousPage = offset == 0 ? null : page;
    return _catalogCurrent(
      operation: ServerMediaCatalogOperation.browse,
      query: null,
      mediaKind: mediaKind,
      offset: offset,
      limit: limit,
      previousPage: previousPage,
      current: current,
    );
  }

  Future<void> _catalogCurrent({
    required ServerMediaCatalogOperation operation,
    required String? query,
    required ServerMediaCatalogKind? mediaKind,
    required int offset,
    required int limit,
    required ServerMediaCatalogPage? previousPage,
    required bool Function() current,
  }) async {
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
    page = null;
    origin = null;
    notifyListeners();
    try {
      await account.withSession((api, session) async {
        bool requestCurrent() => valid() && identical(account.session, session);
        final client = ServerMediaCatalogApi(
          api,
          session.accessToken,
          requestId: _requestId,
        );
        final target = await client.discoverTarget(current: requestCurrent);
        if (!requestCurrent()) return;
        if (offset == 0) {
          final scope = ServerMediaCatalogCacheScope.fromSession(session);
          final resource = ServerMediaCatalogCacheResource(
            installationId: target.installationId,
            installationRevision: target.installationRevision,
            snapshotRevision: target.snapshotRevision,
            jellyfinServiceRevision: target.jellyfinServiceRevision,
          );
          final cached = operation == ServerMediaCatalogOperation.search
              ? await _cache.read(
                  scope,
                  resource,
                  query: query!,
                  mediaKind: mediaKind,
                  limit: limit,
                  current: requestCurrent,
                )
              : await _cache.readBrowse(
                  scope,
                  resource,
                  mediaKind: mediaKind,
                  limit: limit,
                  current: requestCurrent,
                );
          if (!requestCurrent()) return;
          if (cached != null) {
            page = cached;
            origin = ServerMediaResultOrigin.verifiedCache;
            return;
          }
        }
        final value = operation == ServerMediaCatalogOperation.search
            ? await client.searchVerifiedTarget(
                target: target,
                query: query!,
                mediaKind: mediaKind,
                offset: offset,
                limit: limit,
                previousPage: previousPage,
                current: requestCurrent,
              )
            : await client.browseVerifiedTarget(
                target: target,
                mediaKind: mediaKind,
                offset: offset,
                limit: limit,
                previousPage: previousPage,
                current: requestCurrent,
              );
        if (offset == 0) {
          try {
            await _cache.write(
              ServerMediaCatalogCacheScope.fromSession(session),
              value,
              limit: limit,
              current: requestCurrent,
            );
          } catch (_) {
            // Cache persistence cannot turn a verified live response into a
            // route failure. Current authority is still checked below.
          }
        }
        if (requestCurrent()) {
          page = value;
          origin = ServerMediaResultOrigin.live;
        }
      });
    } on LarenorServerException catch (error) {
      if (valid()) failure = error.code;
    } catch (_) {
      if (valid()) failure = 'connection_failed';
    } finally {
      if (!_disposed && operation == _epoch) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> _search(
    Future<ServerMediaCatalogPage> Function(
      ServerMediaCatalogApi api,
      bool Function() current,
    )
    read, {
    required bool Function() current,
  }) async {
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
    page = null;
    origin = null;
    notifyListeners();
    try {
      await account.withSession((api, session) async {
        bool requestCurrent() => valid() && identical(account.session, session);
        final value = await read(
          ServerMediaCatalogApi(
            api,
            session.accessToken,
            requestId: _requestId,
          ),
          requestCurrent,
        );
        if (requestCurrent()) {
          page = value;
          origin = ServerMediaResultOrigin.live;
        }
      });
    } on LarenorServerException catch (error) {
      if (valid()) failure = error.code;
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
