import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../domain/server_component_update_models.dart';
import 'server_component_updates_api.dart';

final class ServerComponentUpdatesController extends ChangeNotifier {
  ServerComponentUpdatesController(this.account)
    : _accountEpoch = account.generation {
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final int _accountEpoch;
  int _epoch = 0;
  bool _disposed = false;
  bool busy = false;
  String? failure;
  ServerComponentUpdateInventory? inventory;
  ServerComponentUpdateCommand? confirmation;
  ServerComponentUpdateJob? job;
  List<ServerComponentUpdateJob> jobs = const [];

  bool get authorized =>
      account.isCurrent(_accountEpoch) &&
      account.initialized &&
      !account.working &&
      account.session?.user.canAdminister == true;

  void _accountChanged() {
    if (!authorized) invalidate();
  }

  void invalidate() {
    _epoch++;
    busy = false;
    failure = null;
    inventory = null;
    confirmation = null;
    job = null;
    jobs = const [];
    _emit();
  }

  Future<void> load({required bool Function() current}) async {
    if (_disposed || busy || !authorized || !current()) return;
    final epoch = _epoch;
    bool valid() => !_disposed && epoch == _epoch && authorized && current();
    busy = true;
    failure = null;
    _emit();
    try {
      final value = await account.withSession((api, session) async {
        if (!valid()) throw const LarenorServerException('cancelled');
        final updates = ServerComponentUpdatesApi(api, session.accessToken);
        final nextInventory = await updates.inventory();
        if (!valid()) throw const LarenorServerException('cancelled');
        final currentConfirmation = confirmation;
        final latest = (await updates.latestJobs()).jobs;
        final matches = currentConfirmation == null
            ? latest
            : latest
                  .where(
                    (item) => item.updateId == currentConfirmation.updateId,
                  )
                  .toList(growable: false);
        final nextJob = matches.isEmpty ? null : matches.first;
        return (inventory: nextInventory, job: nextJob, jobs: latest);
      });
      if (valid()) {
        inventory = value.inventory;
        job = value.job;
        jobs = value.jobs;
      }
    } catch (error) {
      if (valid()) {
        failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        busy = false;
        _emit();
      }
    }
  }

  Future<void> updatePreference({
    required ServerComponentReleasePreference preference,
    required String mode,
    required bool requireUpstreamSignature,
    required bool Function() current,
  }) async {
    if (_disposed || busy || !authorized || !current()) return;
    final epoch = _epoch;
    bool valid() => !_disposed && epoch == _epoch && authorized && current();
    busy = true;
    failure = null;
    _emit();
    try {
      final value = await account.withSession((api, session) async {
        if (!valid()) throw const LarenorServerException('cancelled');
        final updates = ServerComponentUpdatesApi(api, session.accessToken);
        await updates.putPreference(
          current: preference,
          mode: mode,
          requireUpstreamSignature: requireUpstreamSignature,
        );
        if (!valid()) throw const LarenorServerException('cancelled');
        return updates.inventory();
      });
      if (valid()) inventory = value;
    } catch (error) {
      if (valid()) {
        failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        busy = false;
        _emit();
      }
    }
  }

  Future<void> confirmUpdate({
    required ServerInstalledComponentUpdate installed,
    required ServerComponentUpdateReview review,
    required ServerComponentReleasePreference preference,
    required bool Function() current,
  }) async {
    if (_disposed || busy || !authorized || !current()) return;
    final epoch = _epoch;
    bool valid() => !_disposed && epoch == _epoch && authorized && current();
    busy = true;
    failure = null;
    confirmation = null;
    _emit();
    try {
      final result = await account.withSession((api, session) async {
        if (!valid()) throw const LarenorServerException('cancelled');
        final updates = ServerComponentUpdatesApi(api, session.accessToken);
        final command = await updates.confirm(
          installed: installed,
          review: review,
          preference: preference,
        );
        if (!valid()) throw const LarenorServerException('cancelled');
        return (command: command, job: await updates.getJob(command.updateId));
      });
      if (valid()) {
        confirmation = result.command;
        job = result.job;
        jobs = List.unmodifiable([
          result.job,
          ...jobs.where(
            (item) => item.installationId != result.job.installationId,
          ),
        ]);
      }
    } catch (error) {
      if (valid()) {
        failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        busy = false;
        _emit();
      }
    }
  }

  Future<void> cancelJob({
    required ServerComponentUpdateJob job,
    required bool Function() current,
  }) async {
    final selected = job;
    if (_disposed ||
        busy ||
        !selected.cancellable ||
        !authorized ||
        !current()) {
      return;
    }
    final epoch = _epoch;
    bool valid() => !_disposed && epoch == _epoch && authorized && current();
    busy = true;
    failure = null;
    _emit();
    try {
      final result = await account.withSession((api, session) async {
        if (!valid()) throw const LarenorServerException('cancelled');
        return ServerComponentUpdatesApi(
          api,
          session.accessToken,
        ).cancelJob(selected);
      });
      if (valid()) {
        this.job = result;
        jobs = List.unmodifiable([
          result,
          ...jobs.where((item) => item.installationId != result.installationId),
        ]);
      }
    } catch (error) {
      if (valid()) {
        failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        busy = false;
        _emit();
      }
    }
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    account.removeListener(_accountChanged);
    super.dispose();
  }
}
