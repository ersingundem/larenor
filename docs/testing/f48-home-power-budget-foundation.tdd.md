# F48 home power budget Core foundation acceptance

Date: 2026-09-21

Scope: the provider-neutral Core planning and command-journal contract. F48
remains `pending`; this slice does not claim the HTTP/Android journey, live meter
or tariff adapters, supported load workers, or physical electrical safety.

## Exact three acceptance criteria

1. **Verified, revision-bound deterministic budget.** Core accepts main-meter,
   tariff, grid-limit, load-registry, override, account, home, and Core inputs
   only at their exact current revisions. Meter and tariff states must be fresh
   and explicitly `verified`. A bounded plan sorts controllable noncritical loads
   by priority and stable ID, includes exact load revisions, and never exceeds
   the configured grid or shedding safety limits.
2. **Critical-load and manual-control fail-safe.** Critical loads are never
   selected. A load under its anti-oscillation hold is not changed; if remaining
   overload cannot be removed safely, preview fails closed. An active manual
   override produces no automatic action and exposes its expiry, while an
   expired override does not remain authoritative.
3. **Durable preview, confirm, and readback.** Core reserves a command before
   invoking the worker. Timeout/lost acknowledgement stays `uncertain`; repeating
   the same command after restart reads its receipt and never sends it again.
   Exact authority is checked again at readback, only a matching plan hash becomes
   `verified`, and signed records plus an HMAC-linked audit chain expose tampering.

## TDD evidence

- RED: `47175fa0` added the exact three tests before the production module; test
  collection failed because `larenor_server.power_budget` did not exist.
- GREEN: `64db6fa8` added the strict SQLite schema and provider-neutral planner,
  override/hold protection, durable command reservation, readback, and audit.
- Focused command:
  `PYTHONPATH=server /Users/ersingundem/oikos/server/.venv/bin/python -m pytest -q server/tests/test_f48_home_power_budget.py`
- Result: `3 passed`.

## Remaining acceptance gates

- Add authenticated bounded Core HTTP endpoints and a real Android Client to
  isolated Core journey, including lifecycle cancellation and state wording.
- Bind live meter, tariff, and compatible load-control workers without storing
  provider credentials in plans, receipts, or audit export.
- Validate calibrated meters, supported loads, communication loss, manual
  control, and electrical protection with physical hardware. Those manual gates
  remain separate from this software foundation.
