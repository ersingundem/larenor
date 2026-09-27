// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';

import '../../../server/data/server_account_controller.dart';
import '../../../server/domain/server_models.dart';
import '../domain/core_playback_quality_advice.dart';
import 'core_playback_quality_api.dart';

final class CorePlaybackQualityController extends ChangeNotifier {
  CorePlaybackQualityController(this.account, {String Function()? requestId})
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
  CorePlaybackQualityAdvice? advice;

  bool get _authorized =>
      account.isCurrent(_accountGeneration) &&
      account.initialized &&
      !account.working &&
      !account.hasPendingContext &&
      account.session?.context != null &&
      account.session?.sessionFamilyId != null &&
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
    advice = null;
    notifyListeners();
  }

  Future<void> advise(
    CorePlaybackQualityRequest request, {
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
    advice = null;
    notifyListeners();
    try {
      await account.withSession((api, session) async {
        final value = await CorePlaybackQualityApi(
          api,
          session,
          requestId: _requestId,
        ).advise(request);
        if (valid() && identical(account.session, session)) advice = value;
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
