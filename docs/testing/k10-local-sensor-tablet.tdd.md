# K10 local tablet sensors — TDD acceptance

K06 already owns the weekly display schedule, time-zone transitions, dimming,
and foreground screen policy. This independent K10 slice adds no automation
authority and does not reopen that completed scope.

| # | User acceptance | Automated evidence |
| --- | --- | --- |
| 1 | The user explicitly starts one temporary local observation session. Android samples only ambient light and tablet acceleration at a minimum one-second interval, bounds the values, keeps only the latest values in memory, and reports missing sensors separately. No sensor value invokes Home Assistant or another device action. | `KioskSensorPolicyTest`, `kiosk_sensor_models_test.dart` |
| 2 | Leaving the foreground, losing native window/DeX focus, losing the active route or interaction scope, stopping explicitly, or changing the provider retires the exact session and clears the last reading. Foreign sessions, stale sequences, late callbacks, malformed maps, and unverified stop receipts fail closed. Camera availability and permission/busy state are observed without opening the camera or returning an image. | `KioskSensorPolicyTest`, `KioskBridgeTest`, controller and lifecycle widget tests |
| 3 | The discoverable kiosk settings surface presents light, darkness, movement sensitivity, missing hardware, and camera availability in English and Turkish. Start/stop controls remain at least 48 dp and support TalkBack, Tab/Enter, 600/1280 tablet widths, and 200% text. | `kiosk_sensor_screen_test.dart` four-size locale matrix and keyboard test |

The 24-hour battery, thermal, wake-lock and OEM sensor matrix remains a physical
Huawei/Samsung/manual acceptance gate under `MANUAL.KIOSK`. It does not block
K10 software acceptance; K10 advances only after exact-head CI and independent
software review.

Regression review added deterministic route-cover retirement, immediate local
retirement before a native stop receipt, and concurrent out-of-order read
rejection. The native bridge now has a package-internal host/focus seam: its
focused test starts a real policy session, proves 1000 and 10000 ms forwarding,
and proves DeX/window focus and resume-authority loss each stop the owned native
session. A denied or uncertain stop cannot keep showing private sampling as
active. Native permission grant/revocation and OEM availability remain physical
device-verification work.

## Current branch reconciliation — 2026-09-30

24 focused Flutter sensor models/screen tests, 12 Android KioskSensorPolicy/Bridge tests, and scoped analyze across 15 K10/K12 files passed. The independent production review found no remaining software blocker. The queue now records `awaiting_ci`; final exact-head CI and the separate physical `MANUAL.KIOSK` gates remain open.
