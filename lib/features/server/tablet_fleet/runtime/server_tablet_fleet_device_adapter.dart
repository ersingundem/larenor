import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../data/server_tablet_fleet_api.dart';
import '../domain/server_tablet_fleet_models.dart';
import 'tablet_fleet_device_runtime.dart';
import 'tablet_fleet_device_store.dart';

final class ServerTabletFleetDeviceAuthority
    implements TabletFleetDeviceAuthority {
  const ServerTabletFleetDeviceAuthority(this.account);
  final ServerAccountController account;

  @override
  TabletFleetDeviceBinding? currentBinding() {
    final session = account.session;
    final context = session?.context;
    final family = session?.sessionFamilyId;
    if (session == null ||
        context == null ||
        family == null ||
        session.user.mustChangePassword) {
      return null;
    }
    return TabletFleetDeviceBinding(
      serverBaseUrl: session.endpoint.baseUrl,
      coreId: context.coreId,
      homeId: context.homeId,
      accountId: session.user.id,
      sessionFamilyId: family,
    );
  }

  @override
  Future<T> withClient<T>(
    TabletFleetDeviceBinding expected,
    Future<T> Function(TabletFleetDeviceClient client) action,
  ) => account.withSession((raw, session) async {
    if (currentBinding() != expected || session.context == null) {
      throw const LarenorServerException('retired');
    }
    final result = await action(
      _ServerTabletFleetDeviceClient(
        ServerTabletFleetApi(raw, session.accessToken, session.context!),
      ),
    );
    if (currentBinding() != expected) {
      throw const LarenorServerException('retired');
    }
    return result;
  });
}

final class _ServerTabletFleetDeviceClient implements TabletFleetDeviceClient {
  const _ServerTabletFleetDeviceClient(this.api);
  final ServerTabletFleetApi api;

  @override
  Future<ManagedTablet> register({
    required String registrationId,
    required String name,
    required String clientVersion,
    required TabletManagementMode mode,
    required int appliedProfileRevision,
  }) => api.register(
    registrationId: registrationId,
    name: name,
    clientVersion: clientVersion,
    appliedProfileRevision: appliedProfileRevision,
    mode: mode,
  );

  @override
  Future<ManagedTablet> heartbeat(
    ManagedTablet current, {
    required String clientVersion,
    required int appliedProfileRevision,
  }) => api.heartbeat(
    current,
    clientVersion: clientVersion,
    appliedProfileRevision: appliedProfileRevision,
  );

  @override
  Future<ManagedTablet> refresh(ManagedTablet current) async {
    final matches = (await api.list())
        .where((tablet) => tablet.sameAuthority(current))
        .toList(growable: false);
    if (matches.length != 1) {
      throw const LarenorServerException('not_found');
    }
    return matches.single;
  }

  @override
  Future<ManagedTabletCommandPage> poll(
    ManagedTablet current, {
    required int after,
  }) => api.poll(current, after: after);

  @override
  Future<ManagedTabletProfilePublication> readProfile(
    ManagedTablet current,
  ) async {
    final publication = await api.readProfilePublication(current.id);
    if (publication.deviceId != current.id ||
        publication.deviceRevision != current.revision ||
        publication.revision != current.desiredProfileRevision) {
      throw const LarenorServerException('invalid_response');
    }
    return publication;
  }

  @override
  Future<ManagedTablet> acknowledgeProfile(
    ManagedTablet current,
    ManagedTabletProfilePublication publication, {
    required String clientVersion,
  }) async {
    if (publication.deviceId != current.id ||
        publication.deviceRevision != current.revision ||
        publication.revision != current.desiredProfileRevision) {
      throw const LarenorServerException('invalid_request');
    }
    return api.acknowledgeProfilePublication(
      publication,
      clientVersion: clientVersion,
    );
  }

  @override
  Future<ManagedTabletCommand> complete(
    ManagedTablet current,
    ManagedTabletCommand command,
    TabletCommandResult result, {
    required int appliedProfileRevision,
  }) => api.completeVerified(
    current,
    command,
    result,
    appliedProfileRevision: appliedProfileRevision,
  );

  @override
  Future<void> revoke(ManagedTablet current) async {
    await api.revoke(current);
  }
}
