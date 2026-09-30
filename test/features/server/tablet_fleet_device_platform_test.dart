import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/kiosk/data/kiosk_api.dart';
import 'package:larenor/features/kiosk/domain/kiosk_models.dart';
import 'package:larenor/features/kiosk_remote/runtime/native_managed_tablet_source.dart';
import 'package:larenor/features/kiosk_remote/runtime/managed_tablet_profile_store.dart';
import 'package:larenor/features/server/tablet_fleet/domain/server_tablet_fleet_models.dart';
import 'package:larenor/features/server/tablet_fleet/runtime/android_tablet_fleet_device_platform.dart';

final class _Kiosk implements KioskApi {
  var prepared = 0;
  var executed = 0;
  var outcome = KioskOutcome.observed;

  KioskSnapshot get unlocked => KioskSnapshot(
    supported: true,
    deviceOwner: true,
    permitted: true,
    resumed: true,
    focused: true,
    eligibleWindow: true,
    lockState: KioskLockState.none,
    actions: {KioskAction.enter},
  );

  KioskSnapshot get locked => KioskSnapshot(
    supported: true,
    deviceOwner: true,
    permitted: true,
    resumed: true,
    focused: true,
    eligibleWindow: true,
    lockState: KioskLockState.locked,
    actions: {KioskAction.enter},
  );

  @override
  Future<KioskSnapshot> snapshot() async => unlocked;

  @override
  Future<KioskIntent> prepare(KioskAction action) async {
    prepared++;
    return KioskIntent(
      id: '1234567890abcdef',
      action: action,
      snapshot: unlocked,
    );
  }

  @override
  Future<KioskReceipt> execute(KioskIntent intent) async {
    executed++;
    return KioskReceipt(outcome, locked);
  }

  @override
  Future<void> cancel(KioskIntent intent) async {}
}

final class _Profiles implements ManagedTabletProfilePersistence {
  String? value, confirmation;
  @override
  Future<String?> read() async => value;
  @override
  Future<String?> readConfirmation() async => confirmation;
  @override
  Future<void> write(String? next) async => value = next;
  @override
  Future<void> writeConfirmation(String? next) async => confirmation = next;
}

AndroidTabletFleetDevicePlatform _platform(_Kiosk kiosk) =>
    AndroidTabletFleetDevicePlatform(
      kiosk: kiosk,
      actions: const DisabledManagedTabletLocalActions(),
      profiles: ManagedTabletProfileStore(_Profiles()),
      activateProfile: (_, _) async {},
      readActiveProfile: () => null,
    );

void main() {
  test(
    'native snapshot reports Device Owner and lock requires observed readback',
    () async {
      final kiosk = _Kiosk();
      final platform = _platform(kiosk);
      expect(await platform.managementMode(), TabletManagementMode.deviceOwner);
      expect(
        await platform.execute(
          TabletCommandKind.lockKiosk,
          current: () => true,
        ),
        TabletCommandResult.succeeded,
      );
      expect(kiosk.prepared, 1);
      expect(kiosk.executed, 1);

      kiosk.outcome = KioskOutcome.accepted;
      expect(
        await platform.execute(
          TabletCommandKind.lockKiosk,
          current: () => true,
        ),
        TabletCommandResult.failed,
      );
    },
  );

  test(
    'restartClient remains unsupported and does not call native policy',
    () async {
      final kiosk = _Kiosk();
      final platform = _platform(kiosk);
      expect(
        await platform.execute(
          TabletCommandKind.restartClient,
          current: () => true,
        ),
        TabletCommandResult.unsupported,
      );
      expect(kiosk.prepared, 0);
      expect(kiosk.executed, 0);
    },
  );
}
