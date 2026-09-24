import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../../server/tablet_fleet/data/server_tablet_fleet_api.dart';
import 'managed_tablet_credential_store.dart';
import 'managed_tablet_profile_store.dart';

final class ManagedTabletProfileSynchronizer {
  const ManagedTabletProfileSynchronizer({
    required this.account,
    required this.credentials,
    required this.profiles,
    required this.activate,
  });

  final ServerAccountController account;
  final ManagedTabletCredentialStore credentials;
  final ManagedTabletProfileStore profiles;
  final Future<void> Function(AppliedManagedTabletProfile? profile) activate;

  Future<void> synchronize({
    required String clientVersion,
    required bool Function() isCurrent,
  }) async {
    final generation = account.generation;
    final initial = account.session;
    final context = initial?.context;
    if (initial == null ||
        context == null ||
        initial.user.mustChangePassword ||
        !isCurrent()) {
      throw StateError('managed_tablet_action_retired');
    }
    final binding = ManagedTabletBinding(
      serverBaseUrl: initial.endpoint.baseUrl,
      coreId: context.coreId,
      homeId: context.homeId,
      accountId: initial.user.id,
    );
    final enrollment = await credentials.read();
    if (!_current(generation, binding, enrollment, isCurrent)) {
      throw StateError('managed_tablet_action_retired');
    }
    await account.withSession((raw, session) async {
      if (!_sameSession(session, binding) ||
          !_current(generation, binding, enrollment, isCurrent)) {
        throw const LarenorServerException('cancelled');
      }
      final api = ServerTabletFleetApi(raw, session.accessToken, context);
      final publication = await api.readProfilePublication(
        enrollment!.deviceId,
      );
      if (!_current(generation, binding, enrollment, isCurrent)) {
        throw const LarenorServerException('cancelled');
      }
      final applied = await profiles.apply(
        enrollment,
        publication,
        expectedDeviceId: enrollment.deviceId,
        isCurrent: () => _current(generation, binding, enrollment, isCurrent),
        activate: activate,
      );
      if (!_current(generation, binding, enrollment, isCurrent) ||
          applied.revision != publication.revision ||
          applied.digest != publication.digest) {
        throw const LarenorServerException('cancelled');
      }
      await api.acknowledgeProfilePublication(
        publication,
        clientVersion: clientVersion,
      );
      if (!_current(generation, binding, enrollment, isCurrent)) {
        throw const LarenorServerException('cancelled');
      }
    });
  }

  bool _current(
    int generation,
    ManagedTabletBinding binding,
    ManagedTabletEnrollment? enrollment,
    bool Function() isCurrent,
  ) {
    if (!isCurrent() ||
        enrollment == null ||
        enrollment.binding != binding ||
        !account.isCurrent(generation)) {
      return false;
    }
    final session = account.session;
    return session != null && _sameSession(session, binding);
  }

  static bool _sameSession(
    ServerSession session,
    ManagedTabletBinding binding,
  ) =>
      session.endpoint.baseUrl == binding.serverBaseUrl &&
      session.context?.coreId == binding.coreId &&
      session.context?.homeId == binding.homeId &&
      session.user.id == binding.accountId &&
      !session.user.mustChangePassword;
}
