# F46 EV charge planner Core foundation acceptance

Date: 2026-09-21

Scope: the server-side, provider-neutral planning and command journal contract.
F46 remains `pending`; this foundation does not claim an Android flow, HTTP API,
provider ingestion, or acceptance against a physical charger.

## Exact three acceptance criteria

1. **Revision-bound deterministic plan.** A current account can preview a bounded
   schedule only when tariff, solar, home-power-budget, charger, home, Core, and
   schedule authority revisions agree. Provider state is explicit and fresh. The
   plan sorts deterministically, respects departure, target/minimum SoC, maximum
   current, voltage, home power, and session-energy limits, and rejects stale,
   malformed, or unreachable inputs without producing a command.
2. **Expiring manual authority.** An active, revision-bound manual override stops
   scheduling and exposes its expiry without silently weakening safety limits.
   Expired overrides do not remain authoritative. Invalid current, energy, time,
   or provider bounds fail closed.
3. **Preview, confirm, and readback receipt.** Confirmation is reserved durably
   before the charger call. A timeout or lost acknowledgement is `uncertain` and
   the same command is never sent automatically again, including after restart.
   Only matching readback marks it verified. Exact account/session/Core/home/
   charger/revision authority is rechecked, and HMAC-linked events plus signed
   preview/command records detect storage tampering.

## TDD evidence

- RED: `f33bc6e1` introduced the three acceptance tests before the production
  module existed; collection failed on the missing `ev_charging` module.
- GREEN: `50a31402` added the strict SQLite schema and provider-neutral planning,
  confirmation, readback, idempotency, restart, and audit implementation.
- Focused command:
  `PYTHONPATH=server /Users/ersingundem/oikos/server/.venv/bin/python -m pytest -q server/tests/test_f46_ev_charge_planner.py`
- Result: `3 passed`.

## Remaining acceptance gates

- Add an authenticated, bounded Core HTTP contract and a real Client to isolated
  Core journey; add Android tablet UI and cancellation/lifecycle presentation.
- Bind tariff, solar, home power budget, and compatible charger adapters to this
  contract without placing provider secrets in plans or audit exports.
- Validate a supported charger, network/time/tariff outage behavior, and manual
  control on physical hardware. These are manual device gates, not implied by
  this software foundation.

