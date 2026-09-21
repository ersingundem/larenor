# K11 peripheral capability and input foundation

Status: **foundation ready; K11 remains pending**

K11 depends on `K03.remaining` and K08. This slice establishes the local
Flutter/Kotlin contract before any MethodChannel, WebPanel bridge or physical
peripheral adapter is enabled.

## Three acceptance criteria

1. **Provider-scoped capability inventory.** QR, NFC, BLE, USB, TTS and print
   are represented independently with a provider ID and exact revision.
   Unsupported hardware, explicit user opt-out, denied or unknown permission,
   disconnected hardware and missing GMS are separate fail-closed states. A
   local provider can remain ready on a GMS-free device.
2. **Bounded review-only input.** QR/NFC/BLE/USB input uses a strict versioned
   envelope bound to the exact device, policy, session, route, lifecycle and
   provider revisions. Payloads are UTF-8 byte bounded and never become a
   command or JavaScript capability. TTS/print cannot masquerade as input.
3. **Replay and revocation safety.** Event IDs and per-provider sequences reject
   duplicates and out-of-order replay within a bounded cache. Stale samples,
   extra fields, fractional counters, capability drift and revoked authority
   fail closed without invoking hardware or WebPanel code.

## TDD and verification evidence

| Stage | Command | Result |
| --- | --- | --- |
| RED | focused Flutter contract test before production code | Expected compile failure: contract absent; checkpoint `4770e84f` |
| Flutter | `flutter test test/features/kiosk/kiosk_peripheral_contract_test.dart --coverage` | 3/3 passed; 139/158 lines, **88.0%** |
| Kotlin | `./android/gradlew -p android :app:testDebugUnitTest --tests com.ersingundem.larenor.kiosk.KioskPeripheralContractTest` | 3/3 passed, 0 failures/errors |
| Static analysis | focused `flutter analyze` | 0 issues |

## Dependent and manual boundary

No hardware command, print job, speech request, URI, JavaScript or WebPanel
action is dispatched by this contract. K08 wiring, provider settings UI,
Android permission brokers and real QR/NFC/BLE/USB/TTS/print adapters remain
follow-up work. GMS-free Huawei, permission dialogs, cable removal, USB reader
keyboard mode and physical peripherals remain **MANUAL**. Queue progress stays
**22/125 (17.6%)** and feature progress stays **0/63**.
