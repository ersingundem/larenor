// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../../media_catalog/domain/server_media_catalog_models.dart';
import '../domain/server_media_playback_models.dart';
import 'server_media_playback_api.dart';

final class ServerMediaPlaybackController extends ChangeNotifier {
  ServerMediaPlaybackController(this.account, {String Function()? requestId})
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
  ServerMediaPlaybackIntent? intent;
  ServerMediaPlaybackReceipt? receipt;

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
    intent = null;
    receipt = null;
    notifyListeners();
  }

  bool _route(bool Function() current) {
    try {
      return current();
    } catch (_) {
      return false;
    }
  }

  Future<void> prepare(
    ServerMediaCatalogPage page,
    ServerMediaCatalogItem item, {
    required bool Function() current,
  }) async {
    if (_disposed || busy || !_authorized || !_route(current)) return;
    final operation = ++_epoch;
    bool valid() =>
        !_disposed &&
        operation == _epoch &&
        _authorized &&
        _route(current);
    busy = true;
    failure = null;
    intent = null;
    receipt = null;
    notifyListeners();
    try {
      await account.withSession((api, session) async {
        final value = await ServerMediaPlaybackApi(
          api,
          session.accessToken,
          requestId: _requestId,
        ).prepare(page, item);
        if (valid() && identical(account.session, session)) intent = value;
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

  Future<void> play(
    ServerMediaPlaybackTarget target, {
    int startSeconds = 0,
    required bool Function() current,
  }) async {
    final prepared = intent;
    if (_disposed ||
        busy ||
        prepared == null ||
        !_authorized ||
        !_route(current)) {
      if (prepared != null && !_route(current)) retire();
      return;
    }
    final operation = ++_epoch;
    bool valid() =>
        !_disposed &&
        operation == _epoch &&
        _authorized &&
        _route(current);
    // Consume locally before the first authority/network await. A failed
    // command requires a newly prepared server intent.
    intent = null;
    receipt = null;
    busy = true;
    failure = null;
    notifyListeners();
    try {
      await account.withSession((api, session) async {
        final value = await ServerMediaPlaybackApi(
          api,
          session.accessToken,
          requestId: _requestId,
        ).play(prepared, target, startSeconds: startSeconds);
        if (valid() && identical(account.session, session)) receipt = value;
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
