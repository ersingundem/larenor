# F57 room-level local presence fusion

This first Core foundation combines Home Assistant `person` /
`device_tracker`, BLE, and UWB observations behind one closed contract. It is
advisory presence data: it cannot authenticate a person, unlock a door, or
grant access.

| Acceptance | Software evidence |
| --- | --- |
| Exact authority and bounded fusion | Every engine instance is bound to the current Core, home, room, device, model, policy, consent, configured source, account, and session-family revisions. Confidence is limited to 0–1000, inputs to 64, rooms to 32, sources to 16, replay checkpoints to a configured maximum, and enter/exit hysteresis to 1–10 observations. Stale, future, replayed, unknown, or mismatched observations fail closed or produce an explicit `unknown` state. |
| Private local observations stay private | Raw BLE/UWB identifiers are accepted only by the private input model, reduced to bounded hashed replay checkpoints, and never returned or stored as location history. The public estimate contains only bounded confidence, exact public resource revisions, current state, and `advisoryOnly=true` / `grantsAccess=false`. |
| Automation handoff needs exact readback | A presence estimate can reach the worker only with current authority, policy, consent, and estimate snapshots. Only an exact command/request/automation/estimate/transition/device/room receipt with matching `present` readback becomes `verified`; timeout, malformed, mismatched, or ambiguous effects remain `unknown` and duplicate requests never replay the worker. |

`test_f57_room_presence_fusion.py` covers hysteresis, stale and unknown state,
all required revision conflicts, consent withdrawal, source and input bounds,
privacy projection, observation replay, exact automation readback, lost
acknowledgement, and idempotency.

Encrypted durable policy/receipt storage, authenticated management HTTP,
calibration, and the tablet Client are covered by the integration evidence.
F57 remains open for provider adapters, exact-commit CI, and separate physical
ESP32/BLE/UWB/Home Assistant and tablet acceptance. Queue progress remains at
the inherited **22/125** and
selected-feature progress remains **0/63**.
