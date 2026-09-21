# F50 room comfort Core and tablet integration

This slice connects the deterministic F50 planner to authenticated Core storage
and the Android tablet Settings shell. Occupancy stays advisory. Larenor does
not report an HVAC or window change without a provider worker acknowledgement
and exact readback.

| Acceptance | Production boundary | Automated evidence |
| --- | --- | --- |
| Authenticated durable plan | Admin-only HTTP publishes and reads the exact Core/home/account/session-bound plan. Policy, source revisions and device readbacks are persisted with HMAC envelopes; restart restores the same plan and startup rejects tampering or broken references. | Server HTTP tests cover publish/read/restart, unauthenticated rejection, revision conflict and storage tampering. Existing planner tests retain all stale sensor, smoke, freeze, rain and air-quality fail-safe cases. |
| Revision-bound preview and confirm | Preview binds the current plan, home and policy revisions plus a one-time secret hash. Confirm revalidates the current account/session and returns one persistent receipt. With no provider worker, every result is explicitly `unknown`; retry reads the same receipt without replay. | Server tests cover stale preview rejection, one bounded command, unknown worker acknowledgement, retry and restart readback. Client API/controller tests reject malformed scope/results and late account/route callbacks. |
| Discoverable accessible tablet route | Settings exposes Room comfort/Oda konforu through the shared shell and PIN/session gate. The route retires on account, route or lifecycle changes. Plan review is explicit; all actions are at least 48dp and remain keyboard/TalkBack usable at 600/1280 widths and 2x text. | Nineteen Flutter API/controller/route/widget tests cover EN/TR, both widths, authenticated routing, confirmation, exact authority and stale callback retirement. |

Physical temperature, humidity, CO2, VOC, smoke and weather sources plus real
Home Assistant/vendor HVAC and window command/readback remain **MANUAL**. The
software boundary deliberately records `worker_ack_unknown` until that worker
exists. F50 stays open; queue progress remains **22/125 (17.6%)** and selected
feature completion remains **0/63 (0.0%)**.
