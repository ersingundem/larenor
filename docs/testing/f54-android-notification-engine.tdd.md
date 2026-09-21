# F54 Android notification engine acceptance

This slice renders events already authenticated and pulled by the Client. It
uses Android `NotificationManager` and platform channels directly, with no GMS,
FCM, third-party relay, background network credential, or silent power-policy
change.

| Acceptance | Production boundary | Automated evidence |
| --- | --- | --- |
| Permission denial is fail-closed | Android 13+ permission is requested only by the explicit `requestPermission` call while the app is resumed and focused. A denial is recorded and subsequent calls return the denied state without reopening the prompt. Disabled app/channel state prevents reconciliation. | Robolectric exercises first request, denial, and no re-prompt. Flutter channel tests sanitize native error details and reject malformed status. |
| Lock-screen and tap privacy | Native input contains only Core's public projection. Private input must be exactly `Larenor`, empty body, and `redacted=true`; the notification uses `VISIBILITY_PRIVATE` and a generic public version. Tap intents contain no body, title, route, Core ID, home ID, account ID, or token. A random, stored, one-use nonce binds event, sequence, hashed account scope, and subscription revision before the tap enters Flutter. | Kotlin tests inspect the real posted notification and consume the tap once. Flutter tests prove private full text and target never cross the channel and that account scope is hashed. |
| Restart/reboot and replay stay bounded | Native state retains only a hashed binding, subscription/revision, high-water sequence, at most 64 one-use tap keys, and owned notification IDs. Replayed sequences are ignored; out-of-order batches and stale revisions are rejected. Boot/package replacement only marks `recoveryRequired`; the next foreground Core bind performs re-registration. Channel ID is versioned as `larenor_local_notifications_v1`. | Kotlin tests cover duplicate, out-of-order, stale revision, recovery marker, and the absence of a boot-started service. Dart tests cover late route/account retirement. |

## Delivery and device gate

The reported delivery mode is `foregroundPull`: this engine displays a native
notification only after the authenticated Client orchestration has pulled and
validated it. It does not claim always-on background delivery. The power action
opens an explanatory app-specific settings page and never requests or assumes a
Doze exemption. Real Android 13/14/15, Huawei lock screen, reboot, process death,
OEM battery policy, and notification tap behavior remain physical-device
acceptance. F54 remains open, so queue progress stays **17/125** and feature
completion stays **0/63**.
