import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../domain/server_mini_plugin_models.dart';
import 'server_mini_plugin_api.dart';

final class ServerMiniPluginController extends ChangeNotifier {
  ServerMiniPluginController(this.account)
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
  ServerMiniPluginCatalog? catalog;
  List<ServerMiniPluginInstance> instances = const [];
  ServerMiniPluginSnapshot? snapshot;

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
    catalog = null;
    instances = const [];
    snapshot = null;
    _emit();
  }

  Future<void> load(bool Function() current) => _run(current, (api) async {
    catalog = await api.catalog();
    instances = await api.list();
  });

  Future<void> create(String displayName, bool Function() current) =>
      _run(current, (api) async {
        final instance = await api.create(displayName);
        instances = List.unmodifiable([...instances, instance]);
        snapshot = null;
        announcement = 'created';
      });

  Future<void> render(
    ServerMiniPluginInstance instance,
    bool Function() current,
  ) => _run(current, (api) async {
    snapshot = await api.render(instance);
    announcement = 'rendered';
  });

  Future<void> stop(
    ServerMiniPluginInstance instance,
    bool Function() current,
  ) => _run(current, (api) async {
    final stopped = await api.stop(instance);
    instances = List.unmodifiable([
      for (final value in instances)
        if (value.id == stopped.id) stopped else value,
    ]);
    if (snapshot?.pluginId == stopped.id) snapshot = null;
    announcement = 'stopped';
  });

  Future<void> _run(
    bool Function() current,
    Future<void> Function(ServerMiniPluginApi) action,
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
        await action(ServerMiniPluginApi(raw, session.accessToken, _context!));
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
