// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../domain/server_media_catalog_models.dart';
import 'server_media_catalog_api.dart';

/// Owns one explicit Core catalog search. No direct Jellyfin fallback exists.
final class ServerMediaCatalogController extends ChangeNotifier {
  ServerMediaCatalogController(this.account, {String Function()? requestId})
    : _accountGeneration = account.generation,
      _requestId = requestId {
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final int _accountGeneration;
  final String Function()? _requestId;
  int _epoch = 0;
  bool _disposed = false;

  bool busy = false;
  String? failure;
  ServerMediaCatalogPage? page;

  bool get _authorized =>
      account.isCurrent(_accountGeneration) &&
      account.initialized &&
      !account.working &&
      !account.hasPendingContext &&
      account.session?.user.canAdminister == true &&
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
    (api) => api.search(
      installationId: installationId,
      expectedInstallationRevision: expectedInstallationRevision,
      query: query,
      mediaKind: mediaKind,
      offset: offset,
      limit: limit,
    ),
    current: current,
  );

  Future<void> searchCurrent({
    required String query,
    ServerMediaCatalogKind? mediaKind,
    int offset = 0,
    int limit = 24,
    required bool Function() current,
  }) => _search(
    (api) => api.searchCurrent(
      query: query,
      mediaKind: mediaKind,
      offset: offset,
      limit: limit,
    ),
    current: current,
  );

  Future<void> _search(
    Future<ServerMediaCatalogPage> Function(ServerMediaCatalogApi api) read, {
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
    notifyListeners();
    try {
      await account.withSession((api, session) async {
        final value = await read(
          ServerMediaCatalogApi(
            api,
            session.accessToken,
            requestId: _requestId,
          ),
        );
        if (valid() && identical(account.session, session)) page = value;
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
