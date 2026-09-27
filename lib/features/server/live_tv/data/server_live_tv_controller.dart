// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../domain/server_live_tv_models.dart';
import 'server_live_tv_api.dart';

final class ServerLiveTvController extends ChangeNotifier {
  ServerLiveTvController(this.account, {String Function()? requestId})
    : _generation = account.generation,
      _requestId = requestId {
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final int _generation;
  final String Function()? _requestId;
  int _epoch = 0;
  bool _disposed = false;
  bool busy = false;
  String? failure;
  ServerLiveTvSnapshot? snapshot;

  bool get _authorized =>
      account.isCurrent(_generation) &&
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
    snapshot = null;
    notifyListeners();
  }

  Future<void> load({required bool Function() current}) =>
      _run(current, (api, valid) async {
        snapshot = await api.read(current: valid);
      });

  Future<void> schedule(
    ServerLiveTvProgramme programme, {
    required bool Function() current,
  }) => _run(current, (api, valid) async {
    final value = snapshot;
    if (value == null) return;
    await api.schedule(value, programme, current: valid);
    snapshot = await api.read(current: valid);
  });

  Future<void> cancel(
    ServerLiveTvRecording recording, {
    required bool Function() current,
  }) => _run(current, (api, valid) async {
    await api.cancel(recording, current: valid);
    snapshot = await api.read(current: valid);
  });

  Future<void> restart(
    ServerLiveTvRecording recording, {
    required bool Function() current,
  }) => _run(current, (api, valid) async {
    await api.restart(recording, current: valid);
    snapshot = await api.read(current: valid);
  });

  Future<void> _run(
    bool Function() current,
    Future<void> Function(ServerLiveTvApi, bool Function()) action,
  ) async {
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
        await action(
          ServerLiveTvApi(api, session, requestId: _requestId),
          () => valid() && identical(account.session, session),
        );
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
