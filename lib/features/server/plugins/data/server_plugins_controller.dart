import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../domain/server_plugin_models.dart';
import 'server_plugins_api.dart';

class ServerPluginsController extends ChangeNotifier {
  ServerPluginsController(this.account) : _accountEpoch = account.generation {
    account.addListener(_accountChanged);
  }
  final ServerAccountController account;
  final int _accountEpoch;
  int _epoch = 0;
  bool _disposed = false;
  bool busy = false, needsRefresh = false;
  String? failure;
  ServerPluginCatalog? catalog;
  ServerPluginPreview? preview;

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
    busy = false;
    needsRefresh = false;
    failure = null;
    catalog = null;
    preview = null;
    _emit();
  }

  void clearPreview() {
    preview = null;
    _emit();
  }

  Future<void> _run(
    bool Function() current,
    Future<void> Function(ServerPluginsApi, bool Function()) action, {
    bool mutation = false,
  }) async {
    if (_disposed ||
        busy ||
        !_authorized ||
        !current() ||
        (mutation && needsRefresh)) {
      return;
    }
    final epoch = _epoch;
    bool valid() => !_disposed && epoch == _epoch && _authorized && current();
    busy = true;
    failure = null;
    preview = null;
    _emit();
    try {
      await account.withSession((api, session) async {
        if (!valid()) throw const LarenorServerException('cancelled');
        await action(ServerPluginsApi(api, session.accessToken), valid);
      });
      if (valid()) needsRefresh = false;
    } catch (error) {
      if (!valid()) return;
      failure = error is LarenorServerException
          ? error.code
          : 'connection_failed';
      if (mutation) needsRefresh = true;
      if ({
        'unauthorized',
        'forbidden',
        'password_change_required',
        'invalid_response',
        'plugin_catalog_changed',
      }.contains(failure)) {
        catalog = null;
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        busy = false;
        _emit();
      }
    }
  }

  Future<void> load({required bool Function() current}) =>
      _run(current, (api, valid) async {
        final value = await api.catalog();
        if (valid()) catalog = value;
      });

  Future<void> review(
    PluginCatalogEntry entry, {
    required String platform,
    required Map<String, Object?> settings,
    required bool Function() current,
  }) async {
    if (catalog?.entries.contains(entry) != true) return;
    await _run(current, (api, valid) async {
      final value = await api.preview(
        entry,
        platform: platform,
        settings: settings,
      );
      if (valid()) preview = value;
    }, mutation: true);
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
