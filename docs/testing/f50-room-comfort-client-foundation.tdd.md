# F50 room comfort tablet integration — client foundation

This first Client slice consumes the existing deterministic Core plan contract
through a deliberately small gateway. It adds no direct Home Assistant or HVAC
write path and does not infer authority from occupancy.

| Acceptance | Production boundary | Automated evidence |
| --- | --- | --- |
| Exact plan authority | The controller accepts only the exact Core, home, session family, positive authority revisions, bounded 1–32 room list, unique room IDs, and valid room/area revisions. A wrong scope or duplicate room clears retained state and fails closed. | Controller tests cover accepted scope, wrong home, duplicate room, and immutable retained room state. |
| Route and lifecycle retirement | Every load is bound to the controller epoch and a current route/account authority callback. Retiring the route clears the plan, increments the epoch, retires the gateway, and discards a late response. | A held load is completed after authority retirement and cannot repopulate the controller. |
| Accessible tablet projection | The read-only safety plan uses the shared Cupertino surface, explicit blocked/planned state, occupancy as advisory text, a 48dp refresh action, keyboard focus and TalkBack labels. EN/TR layouts are tested at 600 and 1280 logical pixels with 2x text. | Eight focused controller/widget tests cover both locales, both widths, adaptive columns, 2x overflow, keyboard refresh and semantics. |

The authenticated Core HTTP adapter, app-shell discovery and persisted
preview/confirm contract are completed by
`f50-room-comfort-integration.tdd.md`. Physical sensor/HVAC/window checks and a
real provider worker remain **MANUAL** acceptance gates. F50 remains `pending`;
queue progress stays **22/125** and selected feature completion stays **0/63**.
