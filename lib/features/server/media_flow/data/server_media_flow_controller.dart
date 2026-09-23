// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../../media_result_origin.dart';
import '../domain/server_media_flow_models.dart';
import 'server_media_flow_api.dart';
import 'server_media_flow_cache.dart';

/// Owns one explicit central media-flow read. It never polls, retries or
/// acquires a direct media-service address or credential.
final class ServerMediaFlowController extends ChangeNotifier {
  // Keep the public deterministic test seam while storing it privately.
  ServerMediaFlowController(
    this.account, {
    ServerMediaFlowCache? cache,
    String Function()? requestId,
  }) : _accountGeneration = account.generation,
       _cache = cache ?? ServerMediaFlowCache(),
       _requestId = requestId {
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final int _accountGeneration;
  final ServerMediaFlowCache _cache;
  final String Function()? _requestId;
  int _epoch = 0;
  bool _disposed = false;

  bool busy = false;
  String? failure;
  ServerMediaFlowStatus? status;
  ServerMediaResultOrigin? origin;

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
    status = null;
    origin = null;
    notifyListeners();
  }

  Future<void> load(String mediaKey, {required bool Function() current}) async {
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
    status = null;
    origin = null;
    notifyListeners();
    try {
      await account.withSession((api, session) async {
        bool requestCurrent() => valid() && identical(account.session, session);
        final client = ServerMediaFlowApi(
          api,
          session.accessToken,
          requestId: _requestId,
        );
        final authority = await client.readAuthority(
          mediaKey,
          current: requestCurrent,
        );
        if (!requestCurrent()) return;
        final cached = await _cache.read(
          ServerMediaFlowCacheScope.fromSession(session),
          authority,
          current: requestCurrent,
        );
        if (!requestCurrent()) return;
        if (cached != null) {
          status = cached;
          origin = ServerMediaResultOrigin.verifiedCache;
          return;
        }
        final value = await client.readAuthorized(
          authority,
          current: requestCurrent,
        );
        try {
          await _cache.write(
            ServerMediaFlowCacheScope.fromSession(session),
            value,
            current: requestCurrent,
          );
        } catch (_) {
          // Cache persistence is opportunistic; authority is checked below.
        }
        if (requestCurrent()) {
          status = value;
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
