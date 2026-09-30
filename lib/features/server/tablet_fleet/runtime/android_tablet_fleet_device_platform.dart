import '../../../kiosk/data/kiosk_api.dart';
import '../../../kiosk/domain/kiosk_models.dart';
import '../../../kiosk_remote/runtime/native_managed_tablet_source.dart';
import '../../../kiosk_remote/runtime/managed_tablet_profile_store.dart';
import '../domain/server_tablet_fleet_models.dart';
import 'tablet_fleet_device_runtime.dart';
import 'tablet_fleet_device_store.dart';

final class AndroidTabletFleetDevicePlatform
    implements TabletFleetDevicePlatform {
  const AndroidTabletFleetDevicePlatform({
    required this.kiosk,
    required this.actions,
    required this.profiles,
    required this.activateProfile,
    required this.readActiveProfile,
  });

  final KioskApi kiosk;
  final ManagedTabletLocalActions actions;
  final ManagedTabletProfileStore profiles;
  final Future<void> Function(
    ManagedTabletProfileAuthority authority,
    AppliedManagedTabletProfile? profile,
  )
  activateProfile;
  final AppliedManagedTabletProfile? Function() readActiveProfile;

  @override
  Future<TabletManagementMode> managementMode() async {
    final snapshot = await kiosk.snapshot();
    if (!snapshot.supported) {
      throw const KioskException(KioskFailure.unsupported);
    }
    return snapshot.deviceOwner == true
        ? TabletManagementMode.deviceOwner
        : TabletManagementMode.standard;
  }

  @override
  Future<TabletCommandResult> execute(
    TabletCommandKind command, {
    required bool Function() current,
  }) async {
    if (!current()) return TabletCommandResult.denied;
    try {
      switch (command) {
        case TabletCommandKind.refreshDashboard:
          await actions.refreshDashboard(isCurrent: current);
          return current()
              ? TabletCommandResult.succeeded
              : TabletCommandResult.denied;
        case TabletCommandKind.syncProfile:
          return TabletCommandResult.unsupported;
        case TabletCommandKind.restartClient:
          return TabletCommandResult.unsupported;
        case TabletCommandKind.lockKiosk:
          return await _lock(current);
      }
    } on UnsupportedError {
      return TabletCommandResult.unsupported;
    } on KioskException catch (error) {
      return switch (error.failure) {
        KioskFailure.unsupported => TabletCommandResult.unsupported,
        KioskFailure.denied ||
        KioskFailure.pinRequired ||
        KioskFailure.wrongPin ||
        KioskFailure.rateLimited => TabletCommandResult.denied,
        _ => TabletCommandResult.failed,
      };
    } catch (_) {
      return current()
          ? TabletCommandResult.failed
          : TabletCommandResult.denied;
    }
  }

  @override
  Future<TabletCommandResult> applyProfile({
    required TabletFleetDeviceBinding binding,
    required ManagedTablet tablet,
    required ManagedTabletProfilePublication publication,
    required bool Function() current,
  }) async {
    if (!current() ||
        tablet.id != publication.deviceId ||
        tablet.revision != publication.deviceRevision ||
        tablet.desiredProfileRevision != publication.revision) {
      return TabletCommandResult.denied;
    }
    final authority = _profileAuthority(binding, tablet);
    try {
      final applied = await profiles.applyForAuthority(
        authority,
        publication,
        expectedDeviceId: tablet.id,
        isCurrent: current,
        activate: (profile) async {
          if (!current()) throw StateError('retired');
          await activateProfile(authority, profile);
          if (!current()) throw StateError('retired');
        },
      );
      return current() &&
              applied.revision == publication.revision &&
              applied.digest == publication.digest
          ? TabletCommandResult.succeeded
          : TabletCommandResult.denied;
    } catch (_) {
      return current()
          ? TabletCommandResult.failed
          : TabletCommandResult.denied;
    }
  }

  @override
  Future<void> restoreProfile({
    required TabletFleetDeviceBinding binding,
    required ManagedTablet tablet,
    required bool Function() current,
  }) async {
    if (!current()) throw StateError('retired');
    final profile = await profiles.readForAuthority(
      _profileAuthority(binding, tablet),
    );
    if (!current()) throw StateError('retired');
    await activateProfile(_profileAuthority(binding, tablet), profile);
    if (!current()) throw StateError('retired');
  }

  @override
  Future<void> retireProfile({
    required TabletFleetDeviceBinding binding,
    required ManagedTablet tablet,
  }) async {
    final authority = _profileAuthority(binding, tablet);
    if (readActiveProfile()?.belongsToAuthority(authority) == true) {
      await activateProfile(authority, null);
    }
  }

  ManagedTabletProfileAuthority _profileAuthority(
    TabletFleetDeviceBinding binding,
    ManagedTablet tablet,
  ) => ManagedTabletProfileAuthority(
    serverBaseUrl: binding.serverBaseUrl,
    coreId: binding.coreId,
    homeId: binding.homeId,
    accountId: binding.accountId,
    deviceId: tablet.id,
    sourceId: 'fleet:${binding.sessionFamilyId}',
  );

  Future<TabletCommandResult> _lock(bool Function() current) async {
    final before = await kiosk.snapshot();
    if (!current()) return TabletCommandResult.denied;
    if (!before.supported ||
        before.deviceOwner != true ||
        before.permitted != true ||
        !before.actions.contains(KioskAction.enter)) {
      return TabletCommandResult.denied;
    }
    if (before.lockState == KioskLockState.locked) {
      return TabletCommandResult.succeeded;
    }
    final intent = await kiosk.prepare(KioskAction.enter);
    if (!current()) {
      await kiosk.cancel(intent);
      return TabletCommandResult.denied;
    }
    final receipt = await kiosk.execute(intent);
    if (!current()) return TabletCommandResult.denied;
    final after = receipt.snapshot;
    return receipt.outcome == KioskOutcome.observed &&
            after?.deviceOwner == true &&
            after?.permitted == true &&
            after?.lockState == KioskLockState.locked
        ? TabletCommandResult.succeeded
        : TabletCommandResult.failed;
  }
}
