import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../data/larenor_server_api.dart';
import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../domain/server_media_preparation_models.dart';
import '../domain/server_media_inspection_models.dart';
import 'server_media_preparations_api.dart';
import 'server_media_inspections_api.dart';

/// Route-owned observations. Only an explicit action sends or recovers a POST.
class ServerMediaInspectionsController extends ChangeNotifier {
  ServerMediaInspectionsController(this.account, {String Function()? requestId})
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

  static const maximumHistory = 256;
  static const pollInterval = Duration(seconds: 5);
  static const maximumPolls = 60;
  int _epoch = 0, _polls = 0;
  bool _disposed = false, _submitted = false;
  Timer? _timer;
  ServerContext? _identity;
  ServerMediaInspectionRequest? _pending;
  bool busy = false, pollingPaused = false, cancelNeedsRefresh = false;
  String? failure;
  ServerMediaInspectionCapabilities? capabilities;
  ServerMediaPreparation? preparation;
  List<ServerMediaInspection> inspections = const [];
  ServerMediaInspection? selected;
  int? nextBefore;
  bool get canRetryLaunch => _pending != null && !busy;
  bool get canLaunch =>
      !busy &&
      !_submitted &&
      _pending == null &&
      selected == null &&
      capabilities?.inspectionConfigured == true &&
      preparation?.prepared == true &&
      preparation?.catalogCurrent == true;
  bool get _authorized =>
      account.isCurrent(_accountEpoch) &&
      account.initialized &&
      !account.working &&
      account.session?.user.canAdminister == true;
  void _accountChanged() {
    if (!_authorized) invalidate();
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void invalidate() {
    _epoch++;
    _timer?.cancel();
    _timer = null;
    _identity = null;
    busy = false;
    failure = null;
    capabilities = null;
    preparation = null;
    inspections = const [];
    selected = null;
    nextBefore = null;
    _pending = null;
    _submitted = false;
    pollingPaused = false;
    cancelNeedsRefresh = false;
    _polls = 0;
    _emit();
  }

  Future<bool> _run(
    bool Function() current,
    Future<void> Function(LarenorServerApi, String, bool Function()) action,
  ) async {
    if (_disposed || busy || !_authorized || !current()) return false;
    final epoch = _epoch;
    bool valid() => !_disposed && epoch == _epoch && _authorized && current();
    _timer?.cancel();
    _timer = null;
    busy = true;
    failure = null;
    _emit();
    try {
      await account.withSession((api, session) async {
        if (!valid()) throw const LarenorServerException('cancelled');
        await action(api, session.accessToken, valid);
      });
      return valid();
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
          inspections = const [];
          selected = null;
          preparation = null;
          capabilities = null;
          _pending = null;
        }
      }
      return false;
    } finally {
      if (!_disposed && epoch == _epoch) {
        busy = false;
        _emit();
      }
    }
  }

  void _bind(ServerContext identity) {
    if (_identity != null && _identity != identity)
      throw const LarenorServerException('invalid_response');
    _identity ??= identity;
  }

  void _checkRecords(List<ServerMediaInspection> records) {
    if (records.any((r) => r.context != _identity))
      throw const LarenorServerException('invalid_response');
  }

  Future<void> load({required bool Function() current}) async {
    await _run(current, (api, token, valid) async {
      final identity = await api.context(token);
      if (!valid()) return;
      _bind(identity);
      final page = await ServerMediaInspectionsApi(api, token).list();
      if (valid()) {
        _checkRecords(page.inspections);
        inspections = page.inspections;
        nextBefore = page.nextBefore;
      }
    });
  }

  Future<void> loadMore({required bool Function() current}) async {
    final cursor = nextBefore;
    if (cursor == null || inspections.length >= maximumHistory) return;
    await _run(current, (api, token, valid) async {
      final page = await ServerMediaInspectionsApi(
        api,
        token,
      ).list(before: cursor);
      if (!valid()) return;
      if (inspections.length + page.inspections.length > maximumHistory ||
          page.inspections.any(
            (r) => inspections.any((old) => old.id == r.id),
          )) {
        throw const LarenorServerException('invalid_response');
      }
      _checkRecords(page.inspections);
      inspections = List.unmodifiable([...inspections, ...page.inspections]);
      nextBefore = page.nextBefore;
    });
  }

  Future<void> review(
    ServerMediaPreparation previous, {
    required bool Function() current,
  }) async {
    if (_pending != null || busy || !_authorized || !current()) return;
    preparation = null;
    capabilities = null;
    await _run(current, (api, token, valid) async {
      final identity = await api.context(token);
      if (!valid()) return;
      _bind(identity);
      if (previous.plan.coreId != identity.coreId ||
          previous.plan.homeId != identity.homeId) {
        throw const LarenorServerException('invalid_response');
      }
      final record = await ServerMediaPreparationsApi(
        api,
        token,
      ).get(previous.id, previous: previous);
      if (!valid()) return;
      final caps = await ServerMediaInspectionsApi(api, token).capabilities();
      if (valid()) {
        preparation = record;
        capabilities = caps;
        selected = null;
        _submitted = false;
        cancelNeedsRefresh = false;
        pollingPaused = false;
      }
    });
  }

  Future<void> launch({required bool Function() current}) async {
    if (!canLaunch || !_authorized || !current()) return;
    _pending = ServerMediaInspectionRequest(preparation!, _requestId());
    _submitted = true;
    await _submit(current);
  }

  Future<void> retryLaunch({required bool Function() current}) async {
    if (canRetryLaunch) await _submit(current);
  }

  Future<void> _submit(bool Function() current) async {
    final request = _pending;
    if (request == null) return;
    final success = await _run(current, (api, token, valid) async {
      final record = await ServerMediaInspectionsApi(
        api,
        token,
      ).create(request);
      if (valid()) {
        _checkRecords([record]);
        _replace(record);
        selected = record;
        _pending = null;
        _polls = 0;
        pollingPaused = false;
        cancelNeedsRefresh = false;
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
      preparation = null;
      capabilities = null;
      _emit();
    }
    if (success) _schedule(current);
  }

  void _replace(ServerMediaInspection record) {
    inspections = List.unmodifiable(
      [
        record,
        ...inspections.where((r) => r.id != record.id),
      ].take(maximumHistory),
    );
  }

  Future<void> select(
    ServerMediaInspection previous, {
    required bool Function() current,
  }) async {
    if (busy || !_authorized || !current()) return;
    final success = await _run(current, (api, token, valid) async {
      final record = await ServerMediaInspectionsApi(
        api,
        token,
      ).get(previous.id, previous: previous);
      if (valid()) {
        _checkRecords([record]);
        selected = record;
        _replace(record);
        cancelNeedsRefresh = false;
        pollingPaused = false;
        _polls = 0;
      }
    });
    if (success) _schedule(current);
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
    final success = await _run(current, (api, token, valid) async {
      final record = await ServerMediaInspectionsApi(
        api,
        token,
      ).get(previous.id, previous: previous);
      if (valid()) {
        _checkRecords([record]);
        selected = record;
        _replace(record);
        cancelNeedsRefresh = false;
      }
    });
    if (success) _schedule(current);
  }

  void _schedule(bool Function() current) {
    _timer?.cancel();
    _timer = null;
    if (_disposed ||
        !_authorized ||
        !current() ||
        selected?.active != true ||
        failure != null)
      return;
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

  Future<void> cancelSelected({required bool Function() current}) async {
    final previous = selected;
    if (previous == null ||
        !previous.active ||
        previous.cancelRequested ||
        cancelNeedsRefresh ||
        failure != null)
      return;
    final success = await _run(current, (api, token, valid) async {
      final record = await ServerMediaInspectionsApi(
        api,
        token,
      ).cancel(previous);
      if (valid()) {
        _checkRecords([record]);
        selected = record;
        _replace(record);
      }
    });
    if (!success && failure != null) {
      cancelNeedsRefresh = true;
      _emit();
    }
    if (success) _schedule(current);
  }

  void showList() {
    if (busy) return;
    _timer?.cancel();
    _timer = null;
    selected = null;
    cancelNeedsRefresh = false;
    pollingPaused = false;
    _emit();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _timer?.cancel();
    _pending = null;
    account.removeListener(_accountChanged);
    super.dispose();
  }
}
