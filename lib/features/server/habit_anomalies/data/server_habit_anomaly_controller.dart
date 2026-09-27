import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../domain/server_habit_anomaly_models.dart';
import 'server_habit_anomaly_api.dart';

final class ServerHabitAnomalyController extends ChangeNotifier {
  ServerHabitAnomalyController(this.account)
    : _generation = account.generation,
      _accountId = account.session?.user.id,
      _endpoint = account.session?.endpoint.baseUrl,
      _context = account.session?.context {
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final int _generation;
  final String? _accountId, _endpoint;
  final ServerContext? _context;
  int _epoch = 0;
  bool _disposed = false, busy = false, needsRefresh = false;
  String? failure, announcement;
  HabitAnomalyReport? report;

  bool get _authorized {
    final session = account.session;
    return _context != null &&
        account.isCurrent(_generation) &&
        account.initialized &&
        !account.working &&
        session?.user.canAdminister == true &&
        session?.user.id == _accountId &&
        session?.endpoint.baseUrl == _endpoint &&
        session?.context == _context;
  }

  void _accountChanged() {
    if (!_authorized) invalidate();
  }

  void invalidate() {
    _epoch++;
    busy = needsRefresh = false;
    failure = announcement = null;
    report = null;
    _emit();
  }

  Future<void> load({required bool Function() current}) =>
      _run(current, (api) async => report = await api.snapshot());

  Future<void> observe({required bool Function() current}) =>
      _run(current, (api) async {
        report = await api.observeServices(
          ServerHabitAnomalyApi.requestKey('habit-observation'),
        );
        announcement = 'observed';
      });

  Future<void> mark({
    required String label,
    required bool Function() current,
  }) async {
    final selected = report;
    if (selected == null || selected.current.feedback != null) return;
    await _run(current, (api) async {
      report = await api.mark(
        selected,
        label,
        ServerHabitAnomalyApi.requestKey('habit-feedback'),
      );
      announcement = 'marked';
    });
  }

  Future<void> _run(
    bool Function() current,
    Future<void> Function(ServerHabitAnomalyApi api) action,
  ) async {
    if (_disposed || busy || !_authorized || !current() || needsRefresh) return;
    final epoch = _epoch;
    bool valid() => !_disposed && epoch == _epoch && _authorized && current();
    busy = true;
    failure = announcement = null;
    _emit();
    try {
      await account.withSession((raw, session) async {
        if (!valid()) throw const LarenorServerException('cancelled');
        await action(
          ServerHabitAnomalyApi(raw, session.accessToken, _context!),
        );
      });
    } catch (error) {
      if (!valid()) return;
      failure = error is LarenorServerException
          ? error.code
          : 'connection_failed';
      needsRefresh = {
        'connection_failed',
        'timeout',
        'server_error',
        'invalid_response',
      }.contains(failure);
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
