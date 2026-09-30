# F54 local notification production evidence — 2026-09-30

## Production path

- The Client foreground inbox uses `LocalNotificationController` and
  `LocalNotificationRuntimeCoordinator` against the normal Core
  `/api/v1/local-notifications/...` routes. Subscriptions remain account,
  session-family, Core, and home scoped.
- Background Android delivery remains an explicit user action. AndroidX
  WorkManager owns one unique immediate request and one unique periodic request
  with the platform minimum 15-minute interval. Each Worker performs one
  bounded projection pull, then exits. Android and OEM scheduling can delay any
  run, so this path makes no immediate-delivery guarantee.
- The Worker uses a projection-only credential, a fixed HTTPS GET route, no
  cookie jar, no redirects, no ambient authorization header, bounded responses,
  and a persistent high-water mark. A bounded catch-up chain can read two more
  pages; the durable periodic request remains the fallback.
- Private events have no target in the delivery projection. Android posts them
  with `VISIBILITY_PRIVATE` and a generic `publicVersion`; the full event stays
  in the authenticated in-app inbox.
- Direct Core TLS is optional through
  `deploy/larenor-server/unified.tls.compose.yaml`. The CLI validates the
  bounded `0600` certificate and key files and their pairing before Uvicorn
  opens the listener. Plain HTTP remains usable for the foreground inbox, and
  the Client explicitly disables background setup with an HTTPS requirement.

## Named gates

- `server/tests/test_cli.py`: private certificate/key metadata, incomplete and
  mismatched pairs, static errors without path disclosure, and a real normal
  Core HTTPS listener with a test-only trust anchor.
- `tool/tests/unified_tls_deployment_test.py`: fixed read-only TLS mount, paired
  CLI arguments, and a loopback health probe pinned to the mounted certificate.
- `android/app/src/test/kotlin/com/ersingundem/larenor/notifications/LocalNotificationDeliveryTransportTest.kt`:
  trusted test TLS, exact credential-only GET, transient reconnect, duplicate
  sequence rejection, and unsafe target rejection.
- `server/tests/support/f54_native_service_acceptance.py` and
  `LocalNotificationNormalCoreWorkerTest`: normal HTTPS Core, AndroidX's real
  test scheduler, strict transport, sealed store, native renderer, a fresh
  Worker instance, exact cursor dedupe, server revocation, and work retirement.
- `LocalNotificationBridgeTest.privateNotificationIsRedactedAndTapIsOneShotScoped`:
  private lock-screen notification and generic public version.
- `server/tests/support/f54_flutter_acceptance.py`: actual Flutter Client to a
  normal Core TCP process, durable subscription replacement after restart,
  exact event replay without duplication, readback-backed acknowledgements,
  duplicate tap suppression, and one `/today` navigation.
- `test/features/local_notifications/local_notification_platform_card_test.dart`:
  plain HTTP keeps the inbox visible while background enablement is disabled
  with a specific English/Turkish explanation.

## Primary platform contracts

- AndroidX WorkManager 2.12.0 is the official stable release used here:
  <https://developer.android.com/jetpack/androidx/releases/work>
- Periodic work has a 15-minute minimum, is inexact, and can be delayed by
  constraints and system optimizations:
  <https://developer.android.com/develop/background-work/background-tasks/persistent/getting-started/define-work>
- Unique work prevents duplicate schedules, while WorkManager persists it
  across process restarts and device reboots:
  <https://developer.android.com/develop/background-work/background-tasks/persistent/how-to/manage-work>
- Android 13 notification permission is user controlled; scheduled work cannot
  bypass a denial and retires delivery until the user explicitly re-enables it:
  <https://developer.android.com/develop/ui/views/notifications/notification-permission>
- Notification visibility and `publicVersion` are the platform mechanism for
  private lock-screen content:
  <https://developer.android.com/develop/ui/views/notifications/build-notification#lockscreenNotification>
- Android network security trusts system CAs by default for modern targets;
  private trust must be explicitly provisioned rather than bypassed:
  <https://developer.android.com/privacy-and-security/security-config>

## Remaining device evidence

No household device was contacted and no notification was posted outside the
isolated Robolectric/loopback fixtures. A signed Android build still needs one
manual device pass for Android 13 permission denial/grant, reboot rescheduling,
Doze/OEM-delayed execution, lock-screen redaction, and certificate trust on
the operator's real HTTPS hostname. Those gates cannot be inferred from JVM,
Flutter, or loopback Core tests.

## Current verification result

- Production Kotlin notification Bridge/Transport/Worker regressions: **14 passed**, zero skips/failures.
- Normal HTTPS Core to actual WorkManager scheduler, production Worker/store/renderer, restart dedupe and server DELETE revoke: **1 passed**, independently rerun by root before the final enqueue guard review. The repaired guard passed the same actual gate again.
- Flutter local-notification directory: **34 passed, 1 explicit fixture-only skip**; actual foreground Client/normal-Core gate passed in two lifetimes.
- Strict TLS CLI: **5 passed**; deployment overlay policy: **2 passed**; scoped analyze: clean.
- WorkManager enqueue futures are observed without blocking the main thread. Failure marks recovery and cancels tagged work only while the exact lease/platform authority remains current; a replaced lease is unaffected. Recovery is cleared under the same lifecycle lock after current-record validation.

The software slice is awaiting broad exact-head CI. These tests do not close any physical Android/OEM/trust gate.
