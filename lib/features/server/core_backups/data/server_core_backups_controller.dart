import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_core_backup_models.dart';
import 'server_core_backups_api.dart';

final class ServerCoreBackupsController extends ChangeNotifier {
  ServerCoreBackupsController(this.account) {
    _accountGeneration = account.generation;
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  late int _accountGeneration;
  int _generation = 0;
  bool _disposed = false;
  bool busy = false;
  bool actionBusy = false;
  String? failure;
  String? actionFailure;
  CoreBackupPlan? plan;
  CoreBackupCompatibility? compatibility;
  LarenorTransferCancellation? _requestCancellation;
  LarenorTransferCancellation? _exportCancellation;

  bool get _authorized =>
      account.initialized &&
      !account.working &&
      account.session?.user.canAdminister == true;

  void _accountChanged() {
    if (_accountGeneration != account.generation || !_authorized) {
      _accountGeneration = account.generation;
      invalidate();
    }
  }

  void invalidate() {
    _requestCancellation?.cancel();
    _requestCancellation = null;
    _exportCancellation?.cancel();
    _exportCancellation = null;
    _generation++;
    busy = false;
    actionBusy = false;
    failure = null;
    actionFailure = null;
    plan = null;
    compatibility = null;
    _emit();
  }

  bool _current(int epoch, int accountEpoch, bool Function() current) =>
      !_disposed &&
      epoch == _generation &&
      account.isCurrent(accountEpoch) &&
      _authorized &&
      current();

  Future<void> load({required bool Function() current}) async {
    if (_disposed || busy || actionBusy || !_authorized || !current()) return;
    final epoch = _generation, accountEpoch = account.generation;
    final cancellation = LarenorTransferCancellation();
    _requestCancellation = cancellation;
    busy = true;
    failure = null;
    actionFailure = null;
    plan = null;
    compatibility = null;
    _emit();
    try {
      await account.withSession((api, session) async {
        if (!_current(epoch, accountEpoch, current)) {
          throw const LarenorServerException('cancelled');
        }
        final value = await ServerCoreBackupsApi(
          api,
          session.accessToken,
        ).plan(cancellation);
        if (_current(epoch, accountEpoch, current)) plan = value;
      });
    } catch (error) {
      if (_current(epoch, accountEpoch, current)) {
        failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
      }
    } finally {
      if (identical(_requestCancellation, cancellation)) {
        _requestCancellation = null;
      }
      if (!_disposed && epoch == _generation) {
        busy = false;
        _emit();
      }
    }
  }

  Future<CoreBackupExport?> export(
    LarenorRequestSecret passphrase,
    LarenorBinaryDestination destination, {
    required bool Function() current,
  }) async {
    if (_disposed || busy || actionBusy || !_authorized || !current()) {
      passphrase.dispose();
      await destination.cancel();
      return null;
    }
    final epoch = _generation, accountEpoch = account.generation;
    final cancellation = LarenorTransferCancellation();
    _exportCancellation = cancellation;
    CoreBackupExport? exported;
    actionBusy = true;
    actionFailure = null;
    compatibility = null;
    _emit();
    try {
      await account.withSession((api, session) async {
        if (!_current(epoch, accountEpoch, current)) {
          throw const LarenorServerException('cancelled');
        }
        final value = await ServerCoreBackupsApi(
          api,
          session.accessToken,
        ).export(passphrase, destination, cancellation);
        if (_current(epoch, accountEpoch, current)) exported = value;
      });
    } catch (error) {
      if (_current(epoch, accountEpoch, current)) {
        actionFailure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
      }
    } finally {
      passphrase.dispose();
      if (exported == null) await destination.cancel();
      if (identical(_exportCancellation, cancellation)) {
        _exportCancellation = null;
      }
      if (!_disposed && epoch == _generation) {
        actionBusy = false;
        _emit();
      }
    }
    return exported;
  }

  Future<void> preflight(
    CoreBackupManifest manifest, {
    required bool Function() current,
  }) async {
    if (_disposed || busy || actionBusy || !_authorized || !current()) return;
    final epoch = _generation, accountEpoch = account.generation;
    final cancellation = LarenorTransferCancellation();
    _requestCancellation = cancellation;
    actionBusy = true;
    actionFailure = null;
    compatibility = null;
    _emit();
    try {
      await account.withSession((api, session) async {
        if (!_current(epoch, accountEpoch, current)) {
          throw const LarenorServerException('cancelled');
        }
        final value = await ServerCoreBackupsApi(
          api,
          session.accessToken,
        ).preflight(manifest, cancellation);
        if (_current(epoch, accountEpoch, current)) compatibility = value;
      });
    } catch (error) {
      if (_current(epoch, accountEpoch, current)) {
        actionFailure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
      }
    } finally {
      if (identical(_requestCancellation, cancellation)) {
        _requestCancellation = null;
      }
      if (!_disposed && epoch == _generation) {
        actionBusy = false;
        _emit();
      }
    }
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _requestCancellation?.cancel();
    _requestCancellation = null;
    _exportCancellation?.cancel();
    _exportCancellation = null;
    _disposed = true;
    _generation++;
    account.removeListener(_accountChanged);
    super.dispose();
  }
}
