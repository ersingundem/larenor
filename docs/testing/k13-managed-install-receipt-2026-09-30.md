# K13 managed installation terminal receipt

Date: 2026-09-30

## Production contract

Android's `PackageInstaller.Session.commit(IntentSender)` only submits a
sealed session. The final result arrives later through the supplied callback;
submission is therefore never shown as completed. The callback is bound to a
private durable record containing a random request nonce, the originating
Client session, the exact `PackageInstaller` session, the fixed Larenor package
name, the expected version, and the expected signing-certificate digest.

The non-exported receiver accepts only that exact nonce, installer session,
and package name.
`STATUS_SUCCESS` is still insufficient: the receiver reads the installed
package with `PackageManager`, requires the exact expected version, and
requires a single current signing certificate whose SHA-256 digest matches the
verified release. Only then is the receipt `confirmed`. Cancel, failure, and
unknown/lost outcomes stay distinct. An unknown receipt blocks another managed
dispatch and is never retried automatically. The private ledger survives a
Client process restart; malformed private state also blocks dispatch.
An exception before `commit` is attempted is a local preparation failure and
may be retried explicitly. Once `commit` has been called, any exception without
an exact terminal callback is recorded as unknown. Best-effort session abandon
does not prove that PackageInstaller rejected the effect, so it never permits a
second dispatch. A callback that already wrote a terminal receipt cannot be
downgraded by either exception path.

Silent submission remains available only when the existing production
`DevicePolicyManager.isDeviceOwnerApp()` check is true. Physical Device Owner
provisioning and OEM install behavior remain manual acceptance gates.

Primary Android contracts:

- [`PackageInstaller.Session.commit`](https://developer.android.com/reference/android/content/pm/PackageInstaller.Session#commit(android.content.IntentSender)) reports the final result through the callback and may report pending user action.
- [`PackageInstaller.EXTRA_STATUS`](https://developer.android.com/reference/android/content/pm/PackageInstaller#EXTRA_STATUS) defines success, pending, abort, and failure results.
- [`PackageInfo.signingInfo`](https://developer.android.com/reference/android/content/pm/PackageInfo#signingInfo) is populated with `GET_SIGNING_CERTIFICATES`; `getLongVersionCode()` provides the installed version readback.
- [`SessionParams.setRequireUserAction`](https://developer.android.com/reference/android/content/pm/PackageInstaller.SessionParams#setRequireUserAction(int)) documents the advancing platform conditions and requires installers to handle pending user action.

## Focused evidence

The Android test gate exercises the actual private ledger, production
`AndroidApkVerifier`/`PackageManager` readback, receiver status mapping, stale
nonce/session rejection, restart behavior, terminal immutability, and corrupt
state fail-closed behavior. It also distinguishes pre-commit failure from an
ambiguous commit attempt and proves that only the former permits a replacement
dispatch. Flutter tests exercise strict receipt parsing,
pending versus confirmed presentation, and the no-repeat unknown state.

The physical DPC/OEM gate must still prove that a provisioned Device Owner can
complete a real signed update. These software tests do not claim that manual
device evidence.

Root independently repeated the complete Flutter directory: 68 passed.
The focused Android gate completed successfully with 20 tests across ledger/
receiver (9), Bridge (2), APK signature (2) and update security (7). Scoped
Dart analyze is clean. These local software gates await exact-HEAD CI and
remain separate from physical DPC/OEM signed-install proof.
