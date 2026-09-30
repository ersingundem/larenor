import 'package:flutter/foundation.dart';

import '../../../home_resources/data/home_resources_api.dart';
import '../../../home_resources/domain/home_resource_models.dart';
import '../../../proxmox/core_power/proxmox_power_discovery.dart';
import '../../../proxmox/core_power/proxmox_power_models.dart';
import '../../component_egress/domain/server_component_egress_models.dart';
import '../../data/larenor_server_api.dart';
import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../domain/server_power_recovery_models.dart';

final class ServerPowerTargetProvisioningApi {
  const ServerPowerTargetProvisioningApi({
    required this.api,
    required this.token,
    required this.context,
    required this.actorId,
  });

  final LarenorServerApi api;
  final String token;
  final ServerContext context;
  final String actorId;

  Future<List<HomeResourceRecord>> resources() async {
    final values = <HomeResourceRecord>[];
    String? after, snapshot;
    int? userRevision;
    var seen = 0;
    do {
      final page = await HomeResourcesApi(
        api,
        token,
        context,
      ).list(after: after, snapshot: snapshot, limit: 100);
      userRevision ??= page.userRevision;
      seen += page.entries.length;
      if (page.userRevision != userRevision ||
          seen > HomeResourcePage.maximumRecords ||
          seen == HomeResourcePage.maximumRecords && page.nextAfter != null) {
        throw const LarenorServerException('invalid_response');
      }
      values.addAll(
        page.entries.where(
          (entry) => entry.kind == HomeResourceKind.resource && entry.canWrite,
        ),
      );
      after = page.nextAfter;
      snapshot = page.snapshot;
    } while (after != null);
    values.sort((left, right) {
      final order = left.order.compareTo(right.order);
      return order != 0 ? order : left.id.compareTo(right.id);
    });
    return List.unmodifiable(values);
  }

  Future<ProxmoxPowerProviderRef> provision(HomeResourceRecord resource) async {
    if (resource.context != context ||
        resource.kind != HomeResourceKind.resource ||
        !resource.canWrite) {
      throw const LarenorServerException('invalid_request');
    }
    final discovery = await CoreProxmoxTargetDiscoveryApi(
      api,
      token,
    ).discover(resource);
    final target = discovery.target;
    if (discovery.phase != ProxmoxTargetDiscoveryPhase.ready ||
        target == null ||
        !const {
          ProxmoxGuestState.running,
          ProxmoxGuestState.stopped,
        }.contains(target.currentState)) {
      throw const LarenorServerException('power_target_unavailable');
    }
    target.validate();
    final egress = ServerComponentEgressResponse.fromJson(
      serverObject(
        await api.request(
          'GET',
          '/admin/services/${target.serviceId}/outbound-policy',
          token: token,
        ),
      ),
    ).policy;
    if (egress.component !=
            ServerComponentEgressComponent.proxmoxCommandWorker ||
        egress.serviceId != target.serviceId ||
        egress.serviceRevision != target.serviceRevision ||
        egress.revision < 1 ||
        egress.grants.length != 1) {
      throw const LarenorServerException('power_target_unavailable');
    }
    return ProxmoxPowerProviderRef(
      actorId: actorId,
      actorRevision: target.userRevision,
      coreId: target.coreId,
      homeId: target.homeId,
      resourceId: target.resourceId,
      resourceRevision: target.resourceRevision,
      aclRevision: target.aclRevision,
      bindingId: target.bindingId,
      bindingRevision: target.bindingRevision,
      serviceId: target.serviceId,
      serviceRevision: target.serviceRevision,
      egressRevision: egress.revision,
      installationId: target.serviceId,
      node: target.node,
      guestKind: target.guestKind.name,
      guestId: target.guestId,
      statusRevision: target.statusRevision,
    );
  }
}

final class ServerPowerTargetProvisioningController extends ChangeNotifier {
  ServerPowerTargetProvisioningController(this.account) {
    _accountGeneration = account.generation;
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  late int _accountGeneration;
  int _epoch = 0;
  bool _disposed = false;
  bool busy = false;
  String? failure;
  List<HomeResourceRecord> resources = const [];

  bool get _authorized =>
      account.initialized &&
      !account.working &&
      account.session?.context != null &&
      account.session?.user.canAdminister == true;

  void _accountChanged() {
    if (_accountGeneration != account.generation || !_authorized) {
      _accountGeneration = account.generation;
      invalidate();
    }
  }

  bool _current(int epoch, int accountEpoch, bool Function() current) {
    try {
      return !_disposed &&
          epoch == _epoch &&
          account.isCurrent(accountEpoch) &&
          _authorized &&
          current();
    } catch (_) {
      return false;
    }
  }

  Future<T?> _run<T>(
    bool Function() current,
    Future<T> Function(ServerPowerTargetProvisioningApi api) action,
  ) async {
    if (_disposed || busy || !_authorized || !current()) return null;
    final epoch = _epoch, accountEpoch = account.generation;
    T? result;
    busy = true;
    failure = null;
    _emit();
    try {
      await account.withSession((api, session) async {
        if (!_current(epoch, accountEpoch, current) ||
            session.context == null) {
          throw const LarenorServerException('cancelled');
        }
        result = await action(
          ServerPowerTargetProvisioningApi(
            api: api,
            token: session.accessToken,
            context: session.context!,
            actorId: session.user.id,
          ),
        );
      });
    } catch (error) {
      if (_current(epoch, accountEpoch, current)) {
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
    return _current(epoch, accountEpoch, current) ? result : null;
  }

  Future<void> load({required bool Function() current}) async {
    final next = await _run(current, (api) => api.resources());
    if (next != null) {
      resources = next;
      _emit();
    } else if (failure != null) {
      resources = const [];
      _emit();
    }
  }

  Future<ProxmoxPowerProviderRef?> provision({
    required HomeResourceRecord resource,
    required bool Function() current,
  }) {
    final matches = resources.where(
      (value) =>
          value.context == resource.context &&
          value.id == resource.id &&
          value.kind == resource.kind &&
          value.revision == resource.revision &&
          value.aclRevision == resource.aclRevision &&
          value.canWrite == resource.canWrite,
    );
    if (matches.length != 1) return Future.value();
    return _run(current, (api) => api.provision(matches.single));
  }

  void invalidate() {
    _epoch++;
    busy = false;
    failure = null;
    resources = const [];
    _emit();
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    account.removeListener(_accountChanged);
    super.dispose();
  }
}
