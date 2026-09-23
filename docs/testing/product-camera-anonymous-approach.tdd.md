# PRODUCT.CAMERA anonymous approach sensing — TDD acceptance

This independent privacy slice extends the existing K10 tablet sensor session.
It uses Android's proximity sensor only. It does not open a camera or microphone,
identify a person, retain history, or trigger an automation.

| # | User acceptance | Automated evidence |
| --- | --- | --- |
| 1 | A foreground tablet session may sample anonymous near/clear state from `TYPE_PROXIMITY`. The native host validates the physical maximum range, bounds readings, throttles updates, keeps only the latest value in memory, and unregisters the listener when the session retires. | `KioskSensorPolicyTest` and Android compilation |
| 2 | The versioned channel contract has an exact 13-key shape. Malformed, non-finite, negative, out-of-range, stale-session, unavailable-sensor and availability-drift states fail closed. A distance strictly below the sensor maximum means nearby; the maximum itself means clear. | `kiosk_sensor_models_test.dart` and controller tests |
| 3 | The tablet surface reports anonymous approach state in English and Turkish. It remains operable at 600/1280 widths, 200% text, keyboard activation and 48 dp controls; lifecycle, route and native-window focus loss clear the reading. | `kiosk_sensor_screen_test.dart` locale/size and retirement matrix |

Focused evidence on the implementation commit: 13 Flutter tests, the targeted
native policy suite, scoped Flutter analysis, and `git diff --check` passed.

PRODUCT.CAMERA remains pending. Opt-in camera capture, face recognition consent
and deletion controls, 24-hour battery/thermal measurements, Huawei MatePad and
Samsung DeX physical-device verification are separate acceptance gates. This
slice therefore keeps queue progress at **26/125 (20.8%)** and selected-feature
progress at **0/63**.
