import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../domain/server_plugin_job_models.dart';
import '../domain/server_plugin_models.dart';
import 'server_plugin_jobs_api.dart';

/// Holds only this guarded screen's metadata. A lost create response is retried
/// only by an explicit action with the original immutable request identity.
class ServerPluginJobsController extends ChangeNotifier {
  ServerPluginJobsController(this.account, {String Function()? requestId})
    : _accountEpoch = account.generation,
      _requestId = requestId ?? _randomId {
    account.addListener(_accountChanged);
  }
  final ServerAccountController account;
  final int _accountEpoch;
  final String Function() _requestId;
  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  static const pollInterval = Duration(seconds: 5);
  static const maximumPolls = 60;
  int _epoch = 0, _polls = 0;
  bool _disposed = false, _submitted = false;
  Timer? _timer;
  ServerPluginJobRequest? _pending;
  bool busy = false, pollingPaused = false;
  String? failure;
  ServerPluginJobCapabilities? capabilities;
  List<ServerPluginJob> jobs = const [];
  ServerPluginJob? selected;
  List<ServerPluginJobEvent> events = const [];
  int? nextBefore, nextAfter;
  bool get canRetryLaunch => _pending != null && !busy;
  bool get canLaunch =>
      !_submitted && !busy && capabilities?.preflightConfigured == true;
  bool get _authorized =>
      account.isCurrent(_accountEpoch) &&
      account.initialized &&
      !account.working &&
      account.session?.user.canAdminister == true;

  void _accountChanged() {
    if (!_authorized) invalidate();
  }

  void invalidate() {
    _epoch++;
    _timer?.cancel();
    _timer = null;
    busy = false;
    failure = null;
    capabilities = null;
    jobs = const [];
    selected = null;
    events = const [];
    nextBefore = null;
    nextAfter = null;
    _pending = null;
    _submitted = false;
    pollingPaused = false;
    _polls = 0;
    _emit();
  }

  Future<bool> _run(
    bool Function() current,
    Future<void> Function(ServerPluginJobsApi, bool Function()) action,
  ) async {
    if (_disposed || busy || !_authorized || !current()) return false;
    final epoch = _epoch;
    bool valid() => !_disposed && epoch == _epoch && _authorized && current();
    _timer?.cancel();
    _timer = null;
    busy = true;
    failure = null;
    _emit();
    var succeeded = false;
    try {
      await account.withSession((api, session) async {
        if (!valid()) throw const LarenorServerException('cancelled');
        await action(ServerPluginJobsApi(api, session.accessToken), valid);
      });
      succeeded = valid();
    } catch (error) {
      if (valid()) {
        failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
        pollingPaused = selected?.active == true;
        if ({
          'unauthorized',
          'forbidden',
          'password_change_required',
        }.contains(failure)) {
          selected = null;
          events = const [];
          jobs = const [];
          capabilities = null;
          _pending = null;
        }
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        busy = false;
        _emit();
      }
    }
    return succeeded;
  }

  void _schedule(bool Function() current) {
    _timer?.cancel();
    _timer = null;
    if (_disposed ||
        !_authorized ||
        !current() ||
        selected?.active != true ||
        failure != null) {
      return;
    }
    if (_polls >= maximumPolls) {
      pollingPaused = true;
      _emit();
      return;
    }
    _timer = Timer(pollInterval, () {
      _timer = null;
      if (!_disposed &&
          _authorized &&
          current() &&
          !busy &&
          selected?.active == true) {
        _polls++;
        unawaited(refreshSelected(current: current, automatic: true));
      }
    });
  }

  Future<void> load({required bool Function() current}) async {
    await _run(current, (api, valid) async {
      final caps = await api.capabilities();
      if (!valid()) return;
      final page = await api.list();
      if (valid()) {
        capabilities = caps;
        jobs = page.jobs;
        nextBefore = page.nextBefore;
      }
    });
    _schedule(current);
  }

  Future<void> loadMore({required bool Function() current}) async {
    final cursor = nextBefore;
    if (cursor == null || jobs.length >= 250) return;
    await _run(current, (api, valid) async {
      final page = await api.list(before: cursor);
      if (page.jobs.any((j) => jobs.any((existing) => existing.id == j.id))) {
        throw const LarenorServerException('invalid_response');
      }
      if (valid()) {
        jobs = List.unmodifiable([...jobs, ...page.jobs]);
        nextBefore = page.nextBefore;
      }
    });
    _schedule(current);
  }

  Future<void> launch(
    ServerPluginPreview preview, {
    required bool Function() current,
  }) async {
    if (!canLaunch ||
        !_authorized ||
        !current() ||
        preview.expired(DateTime.now().toUtc())) {
      return;
    }
    _submitted = true;
    _pending = ServerPluginJobRequest(preview, _requestId());
    await _submit(current);
  }

  Future<void> retryLaunch({required bool Function() current}) async {
    if (!canRetryLaunch) return;
    // Recover the existing idempotency key even after preview expiry. The
    // Server may already have committed it; never renew the preview here.
    await _submit(current);
  }

  Future<void> _submit(bool Function() current) async {
    final request = _pending;
    if (request == null) return;
    final success = await _run(current, (api, valid) async {
      final job = await api.create(request);
      if (valid()) {
        selected = job;
        events = const [];
        nextAfter = null;
        _pending = null;
        _polls = 0;
        pollingPaused = false;
        _replace(job);
      }
    });
    if (!success &&
        failure != null &&
        !{
          'connection_failed',
          'timeout',
          'server_error',
          'invalid_response',
        }.contains(failure)) {
      _pending = null;
      _emit();
    }
    if (success) _schedule(current);
  }

  void _replace(ServerPluginJob job) {
    jobs = List.unmodifiable(
      [job, ...jobs.where((j) => j.id != job.id)].take(250),
    );
  }

  Future<void> select(
    ServerPluginJob job, {
    required bool Function() current,
  }) async {
    if (!_authorized || !current() || busy) return;
    selected = job;
    events = const [];
    nextAfter = null;
    _polls = 0;
    await refreshSelected(current: current);
  }

  void clearSelected() {
    _timer?.cancel();
    _timer = null;
    selected = null;
    events = const [];
    nextAfter = null;
    pollingPaused = false;
    _emit();
  }

  Future<void> refreshSelected({
    required bool Function() current,
    bool automatic = false,
  }) async {
    final previous = selected;
    if (previous == null) return;
    if (!automatic) {
      _polls = 0;
      pollingPaused = false;
    }
    final success = await _run(current, (api, valid) async {
      final job = await api.get(previous.id, previous: previous);
      if (!valid()) return;
      final page = events.length < 250
          ? await api.events(job.id, after: events.lastOrNull?.sequence ?? 0)
          : null;
      if (valid()) {
        selected = job;
        _replace(job);
        if (page != null) {
          events = List.unmodifiable([...events, ...page.events]);
          nextAfter = page.nextAfter;
        }
      }
    });
    if (success) _schedule(current);
  }

  Future<void> loadMoreEvents({required bool Function() current}) async {
    if (nextAfter == null || events.length >= 250 || selected == null) return;
    await refreshSelected(current: current);
  }

  Future<void> cancelSelected({required bool Function() current}) async {
    final previous = selected;
    if (previous == null ||
        !previous.active ||
        previous.cancelRequested ||
        failure != null) {
      return;
    }
    final success = await _run(current, (api, valid) async {
      final job = await api.cancel(previous);
      if (valid()) {
        selected = job;
        _replace(job);
      }
    });
    if (success) _schedule(current);
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _timer?.cancel();
    account.removeListener(_accountChanged);
    super.dispose();
  }
}
