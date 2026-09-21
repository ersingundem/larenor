# F51 interactive floor plan Core foundation acceptance

Date: 2026-09-21

Scope: bounded layout persistence, authorization, audit, export, and entity-state
projection in Core. F51 remains `pending`; no Android renderer, entity action,
camera/device calibration, or physical tablet acceptance is claimed here.

## Exact three acceptance criteria

1. **Bounded optimistic layout edits.** Floors, rooms, anchors, normalized points,
   and vector shapes have fixed count, identifier, label, coordinate, and geometry
   limits. Every room/floor/target reference is closed. Edits bind exact Core,
   home, layout, entity-registry, resource, account, session, and grant authority;
   use optimistic revisions; survive restart; and replay only byte-equivalent
   idempotency requests.
2. **Role-scoped, tamper-evident storage and export.** Read and edit grants are
   separate and fail closed. Layouts, request receipts, and the append-only event
   chain are HMAC-bound, with home isolation and mutation detection. The bounded
   export contains layout and public revision data only; session, token, live
   entity state, and provider credentials are absent.
3. **Revision-bound entity projection.** Only entities anchored in the current
   layout may be projected. Entity and registry revisions must exactly match the
   current layout authority. Fresh explicitly verified state is `live`; missing,
   unavailable, provider-stale, or aged observations remain visibly `stale` and
   never fabricate a current value.

## TDD evidence

- RED: `be16e4c5` introduced the three acceptance tests before the production
  module existed; collection failed on the missing `floor_plan` package.
- GREEN: `c8628319` added strict storage, bounded validation, optimistic edits,
  role grants, signed audit/export, and revision-bound entity projection.
- Focused command:
  `PYTHONPATH=server /Users/ersingundem/oikos/server/.venv/bin/python -m pytest -q server/tests/test_f51_floor_plan_core.py`
- Result: `3 passed`.

## Remaining acceptance gates

- Add authenticated bounded HTTP endpoints and the Android tablet renderer,
  accessible list alternative, zoom/touch/keyboard behavior, and lifecycle-safe
  account/home switching.
- Resolve anchors against real Home Assistant entity and Larenor resource
  registries, then add explicitly authorized entity actions with readback.
- Validate 600/1200 widths, 2x text, DeX resizing, Huawei tablet behavior, and 3D
  performance separately. A saved vector plan is not an automatically measured
  floor plan.
