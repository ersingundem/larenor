# F53 managed tablet production acceptance — 2026-09-30

## Supported production path

The Tablet management screen now contains an explicit **Register this tablet**
control. Registration is never started by app launch. The client derives the
reported management mode from the Android kiosk snapshot, binds the retained
record to the exact server, Core, home, account and session family, and resumes
heartbeat and command polling only while that authority remains current.

Delivered commands are written to secure storage before any local effect. The
result is written before Core completion. A restart with a reservation but no
result completes the command as failed and never repeats the unknown effect;
a lost completion acknowledgement replays only the same completion receipt.
Revocation, logout, account replacement, home replacement and session-family
replacement retire the local record and stop polling.

`syncProfile` reads the exact current Core publication after the command is
durably reserved. The client validates the device/profile revision and digest,
atomically installs the profile under a tablet-fleet authority fingerprint,
activates it, and only then acknowledges the applied revision to Core. That
authority is separate from K07 MQTT pairing, so F53 enrollment never enables a
broker listener. Restart restores only the same server/Core/home/account,
session-family and tablet profile; revocation clears that active authority.
K07 and F53 publish through one authority-scoped activation boundary: an
absent, revoked or delayed K07 callback can clear only its own fingerprint and
cannot erase a newer F53 profile. Both paths wait for the window and idle
providers to apply a verified profile, while logout retires both authorities.

`lockKiosk` is exposed only when Core reports `kioskLock`, then the client
rechecks the native Device Owner, lock-task allowlist and observed locked state.
The legacy `restartClient` wire value remains parseable for stored history, but
Core no longer advertises or issues it: Android's DevicePolicyManager reboot API
reboots the device and is not an application-restart implementation.

Core's `deviceOwner` field is a client-reported capability. It is not remote
attestation. Physical Device Owner provisioning and OEM lock-task behavior stay
in the final manual Android gate.

Primary Android contracts:

- [Lock task mode](https://developer.android.com/work/dpc/dedicated-devices/lock-task-mode)
- [DevicePolicyManager](https://developer.android.com/reference/android/app/admin/DevicePolicyManager)
- [Dedicated-device cookbook](https://developer.android.com/work/dpc/dedicated-devices/cookbook)

## Named evidence

- `uv run --project server pytest -q server/tests/test_tablet_fleet.py server/tests/test_f53_tablet_fleet_policy.py` — **7 passed**. Registration replay, exact profile/device revisions, heartbeat, role/home/session-family rejection, revocation, command journal and truthful capabilities.
- `flutter test test/features/kiosk_remote/managed_tablet_runtime_owner_test.dart test/features/kiosk_remote/managed_tablet_profile_store_test.dart test/features/kiosk_remote/managed_tablet_runtime_scope_test.dart test/features/server/tablet_fleet_device_platform_test.dart test/features/server/tablet_fleet_device_runtime_test.dart test/features/server/server_tablet_fleet_test.dart` — **50 passed**. Runtime reservation/recovery, queued authority retirement, exact profile install/rollback/restart, explicit opt-in, native lock readback, and the composed K07/F53 profile-isolation/logout gate.
- `server/.venv/bin/python server/tests/support/f53_flutter_acceptance.py` — **4 Flutter process phases passed** against normal Uvicorn/Core TCP. The client explicitly registered, fetched and installed the real Core profile publication, acknowledged revision 2, completed the exact `syncProfile` command, restored the active profile after Core/client restart, rejected a wrong-home route and revoked itself with fresh Core readback.

The acceptance fixture uses only isolated temporary Core data and a local
observed profile activation file. It does not provision Device Owner or mutate
a household tablet.
