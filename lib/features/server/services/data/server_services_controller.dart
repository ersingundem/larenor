import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../domain/server_service_models.dart';
import 'server_services_api.dart';

/// A visible, unlocked administrator route owns these records. Writes are
/// single-flight and never retried after a timeout or revision conflict.
class ServerServicesController extends ChangeNotifier {
  ServerServicesController(this.account) : _accountEpoch = account.generation {
    account.addListener(_accountChanged);
  }
  final ServerAccountController account;
  final int _accountEpoch;
  int _epoch = 0;
  bool _disposed = false;
  bool busy = false, needsRefresh = false;
  String? failure;
  List<ServerService> services = const [];

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
    failure = null;
    needsRefresh = false;
    services = const [];
    _emit();
  }

  bool _current(int epoch, bool Function() current) =>
      !_disposed && epoch == _epoch && _authorized && current();

  Future<void> _run(
    bool Function() current,
    Future<void> Function(ServerServicesApi, bool Function()) action, {
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
    bool valid() => _current(epoch, current);
    busy = true;
    failure = null;
    _emit();
    try {
      await account.withSession((api, session) async {
        if (!valid()) throw const LarenorServerException('cancelled');
        await action(ServerServicesApi(api, session.accessToken), valid);
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
      }.contains(failure)) {
        services = const [];
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
        final value = await api.list();
        if (valid()) services = value;
      });

  Future<void> save({
    ServerService? previous,
    required String name,
    required ServerServiceKind kind,
    required String baseUrl,
    Map<String, String>? credentials,
    required bool Function() current,
  }) => _save(
    current,
    (api) => previous == null
        ? api.create(
            name: name,
            kind: kind,
            baseUrl: baseUrl,
            credentials: credentials ?? {},
          )
        : api.update(
            previous,
            name: name,
            baseUrl: baseUrl,
            credentials: credentials,
          ),
  );

  Future<void> check(
    ServerService service, {
    required bool Function() current,
  }) => _save(current, (api) => api.check(service));

  Future<void> _save(
    bool Function() current,
    Future<ServerService> Function(ServerServicesApi) action,
  ) => _run(current, (api, valid) async {
    final value = await action(api);
    if (valid()) {
      services = List.unmodifiable(
        [...services.where((item) => item.id != value.id), value]
          ..sort((a, b) => a.name.compareTo(b.name)),
      );
    }
  }, mutation: true);

  Future<void> forget(
    ServerService service, {
    required bool Function() current,
  }) => _run(current, (api, valid) async {
    await api.forget(service);
    if (valid()) {
      services = List.unmodifiable(
        services.where((item) => item.id != service.id),
      );
    }
  }, mutation: true);

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
