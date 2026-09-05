import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../data/larenor_server_api.dart';
import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../../plugins/data/server_plugins_api.dart';
import '../../plugins/domain/server_plugin_models.dart';
import '../domain/server_media_preparation_models.dart';
import 'server_media_preparations_api.dart';

/// Route-owned metadata. Durable history is always read from the Server; only
/// an explicit retry can recover an uncertain write using its original request.
class ServerMediaPreparationsController extends ChangeNotifier {
  ServerMediaPreparationsController(
    this.account, {
    String Function()? requestId,
  }) : _accountEpoch = account.generation,
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

  int _epoch = 0;
  bool _disposed = false;
  bool busy = false, cancelNeedsRefresh = false;
  String? failure;
  List<ServerMediaPreparation> preparations = const [];
  ServerMediaPreparation? selected;
  int? nextBefore;
  ServerContext? context;
  ServerPluginCatalog? catalog;
  MediaPreparationRequest? _pending;
  bool get canRetryCreate => _pending != null && !busy;
  bool get canCreate =>
      !busy && _pending == null && context != null && catalog != null;
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
    busy = false;
    failure = null;
    preparations = const [];
    selected = null;
    nextBefore = null;
    context = null;
    catalog = null;
    _pending = null;
    cancelNeedsRefresh = false;
    _emit();
  }

  Future<bool> _run(
    bool Function() current,
    Future<void> Function(LarenorServerApi, String, bool Function()) action,
  ) async {
    if (_disposed || busy || !_authorized || !current()) return false;
    final epoch = _epoch;
    bool valid() => !_disposed && epoch == _epoch && _authorized && current();
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
        if ([
          'unauthorized',
          'forbidden',
          'password_change_required',
        ].contains(failure)) {
          preparations = const [];
          selected = null;
          context = null;
          catalog = null;
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

  Future<void> load({required bool Function() current}) async {
    await _run(current, (api, token, valid) async {
      final page = await ServerMediaPreparationsApi(api, token).list();
      if (valid()) {
        preparations = page.preparations;
        nextBefore = page.nextBefore;
      }
    });
  }

  Future<void> loadMore({required bool Function() current}) async {
    final cursor = nextBefore;
    if (cursor == null || preparations.length >= 100) return;
    await _run(current, (api, token, valid) async {
      final page = await ServerMediaPreparationsApi(
        api,
        token,
      ).list(before: cursor);
      if (page.preparations.any(
        (r) => preparations.any((old) => old.id == r.id),
      ))
        throw const LarenorServerException('invalid_response');
      if (valid()) {
        preparations = List.unmodifiable([
          ...preparations,
          ...page.preparations,
        ]);
        nextBefore = page.nextBefore;
      }
    });
  }

  Future<void> prepareDraft({required bool Function() current}) async {
    if (_pending != null) return;
    await _run(current, (api, token, valid) async {
      final identity = await api.context(token);
      if (!valid()) return;
      final entries = await ServerPluginsApi(api, token).catalog();
      if (valid()) {
        context = identity;
        catalog = entries;
        selected = null;
        cancelNeedsRefresh = false;
      }
    });
  }

  void closeDraft() {
    if (busy || _pending != null) return;
    context = null;
    catalog = null;
    _emit();
  }

  Future<void> create({
    required String platform,
    required MediaPreparationSettings settings,
    required bool Function() current,
  }) async {
    if (!canCreate || !_authorized || !current()) return;
    _pending = MediaPreparationRequest(
      requestId: _requestId(),
      context: context!,
      catalog: catalog!,
      platform: platform,
      settings: settings,
    );
    await _submit(current);
  }

  Future<void> retryCreate({required bool Function() current}) async {
    if (canRetryCreate) await _submit(current);
  }

  Future<void> _submit(bool Function() current) async {
    final request = _pending;
    if (request == null) return;
    final success = await _run(current, (api, token, valid) async {
      final result = await ServerMediaPreparationsApi(
        api,
        token,
      ).create(request);
      if (valid()) {
        selected = result;
        _replace(result);
        _pending = null;
        context = null;
        catalog = null;
        cancelNeedsRefresh = false;
      }
    });
    if (!success &&
        failure != null &&
        ![
          'connection_failed',
          'timeout',
          'server_error',
          'invalid_response',
        ].contains(failure)) {
      _pending = null;
      context = null;
      catalog = null;
      _emit();
    }
  }

  Future<void> select(
    ServerMediaPreparation record, {
    required bool Function() current,
  }) async {
    await _run(current, (api, token, valid) async {
      final result = await ServerMediaPreparationsApi(
        api,
        token,
      ).get(record.id, previous: record);
      if (valid()) {
        selected = result;
        _replace(result);
        cancelNeedsRefresh = false;
      }
    });
  }

  Future<void> refreshSelected({required bool Function() current}) async {
    final record = selected;
    if (record != null) await select(record, current: current);
  }

  Future<void> cancelSelected({required bool Function() current}) async {
    final record = selected;
    if (record == null || !record.prepared || cancelNeedsRefresh || busy)
      return;
    final success = await _run(current, (api, token, valid) async {
      final result = await ServerMediaPreparationsApi(
        api,
        token,
      ).cancel(record);
      if (valid()) {
        selected = result;
        _replace(result);
      }
    });
    if (!success && failure != null) {
      cancelNeedsRefresh = true;
      _emit();
    }
  }

  void showList() {
    if (!busy) {
      selected = null;
      cancelNeedsRefresh = false;
      _emit();
    }
  }

  void _replace(ServerMediaPreparation record) {
    preparations = List.unmodifiable(
      [record, ...preparations.where((r) => r.id != record.id)].take(100),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    account.removeListener(_accountChanged);
    _pending = null;
    super.dispose();
  }
}
