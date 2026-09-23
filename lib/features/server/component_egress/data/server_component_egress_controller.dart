import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../../services/domain/server_service_models.dart';
import '../domain/server_component_egress_models.dart';
import 'server_component_egress_api.dart';

/// Owns one administrator-visible service policy. Mutations are never retried:
/// an uncertain result requires an explicit authoritative read first.
final class ServerComponentEgressController extends ChangeNotifier {
  ServerComponentEgressController(this.account, this.service)
    : _accountEpoch = account.generation {
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final ServerService service;
  final int _accountEpoch;
  int _epoch = 0;
  bool _disposed = false;
  bool busy = false, needsRefresh = false;
  String? failure;
  ServerComponentEgressResponse? value;
  ServerComponentEgressResolution? resolution;

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
    value = null;
    resolution = null;
    _emit();
  }

  bool _current(int epoch, bool Function() current) =>
      !_disposed && epoch == _epoch && _authorized && current();

  Future<void> load({required bool Function() current}) {
    resolution = null;
    return _run(current, (api, valid) async {
      final response = await api.read(service);
      if (valid()) value = response;
    });
  }

  Future<void> resolve({required bool Function() current}) {
    resolution = null;
    return _run(current, (api, valid) async {
      if (value == null) {
        throw const LarenorServerException('invalid_request');
      }
      final response = await api.resolve(service);
      if (valid()) resolution = response;
    });
  }

  void retireResolution() {
    if (_disposed || resolution == null) return;
    resolution = null;
    _emit();
  }

  Future<void> replace({
    ServerComponentEgressGrant? grant,
    required bool Function() current,
  }) => _run(current, (api, valid) async {
    final previous = value;
    if (previous == null) throw const LarenorServerException('invalid_request');
    final response = await api.replace(service, previous, grant: grant);
    if (valid()) {
      value = response;
      resolution = null;
    }
  }, mutation: true);

  Future<void> _run(
    bool Function() current,
    Future<void> Function(ServerComponentEgressApi, bool Function()) action, {
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
      await account.withSession((raw, session) async {
        if (!valid()) throw const LarenorServerException('cancelled');
        await action(ServerComponentEgressApi(raw, session.accessToken), valid);
      });
      if (valid()) needsRefresh = false;
    } catch (error) {
      if (!valid()) return;
      failure = error is LarenorServerException
          ? error.code
          : 'connection_failed';
      if (mutation) {
        needsRefresh = true;
        value = null;
        resolution = null;
      }
      if ({
        'unauthorized',
        'forbidden',
        'password_change_required',
        'invalid_response',
      }.contains(failure)) {
        value = null;
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
