# F47 solar and home-battery priorities acceptance

This package connects the fail-closed Core planning boundary to an authenticated
HTTP contract and a route-owned Android tablet surface. Queue progress remains
at 22/125 and selected feature progress remains at 0/63: a production inverter
provider and physical inverter acceptance remain explicit manual gates before
F47 can be counted as complete.

Exactly three user acceptance criteria are in scope:

1. The authenticated Core endpoint returns production, consumption, tariff,
   battery and backup-reserve-percent inputs only when their exact Core, home,
   resource, provider and revision bindings are current. The deterministic plan
   is advisory and can never authorize an automatic inverter write.
2. A writable administrator must preview and explicitly confirm a bounded
   charge or discharge command. The Client reports success only after a separate
   exact receipt readback; stale account, session-family, route, lifecycle,
   input or inverter authority fails closed. Physical inverter execution and
   readback remain `MANUAL` until a supported provider is verified on hardware.
3. The EN/TR tablet surface exposes the same plan and authority state at 600 and
   1280 logical pixels with 2x text, 48dp actions, TalkBack live status and
   Enter/Space keyboard activation. Backgrounding, route retirement or account
   change retires pending confirmation and drops late callbacks.

## TDD evidence

The original RED commit `91187368` failed collection because the Core package
did not exist. The integration RED commit `ef2f6251` required authenticated HTTP
and Android Client contracts. The GREEN matrix contains six focused Server
tests and eight focused Flutter tests covering deterministic bounded planning,
revision drift, explicit preview-confirm-readback, lost ACK idempotency, audit
tamper rejection, strict response parsing, stale callback retirement, and the
four-locale/size accessibility matrix.
