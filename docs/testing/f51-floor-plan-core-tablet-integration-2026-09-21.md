# F51 interactive floor plan Core and tablet integration

Date: 2026-09-21

Status: software integration slice complete; F51 remains `pending`. The progress
counter stays at 22/125 and physical acceptance stays at 0/63.

## Exact three acceptance criteria

1. **Current Core authority and real references.** Authenticated HTTP reads and
   admin layout replacements derive account, session, Core, home, layout,
   Home Assistant binding, resource and grant revisions from current signed
   storage. Resource and entity anchors must resolve to a current readable
   registry record with the exact target revision. Unknown, hidden, changed or
   cross-home anchors fail closed.
2. **Bounded, idempotent transport.** The API accepts only the bounded closed
   floor, room, anchor, vector and point schema. Equivalent lost-ack retries
   return the stored receipt; the same request identifier with different bytes
   conflicts. Reads, history and exports recheck live authority and never return
   retained layout evidence after registry drift.
3. **Route-owned accessible tablet view.** The Android Client has a strict
   authenticated Core adapter and owns it for one exact account, endpoint,
   Core, home, route and foreground lifecycle. Late responses are discarded.
   The 600 and 1280 tablet layouts expose vector and accessible list views,
   48dp controls, keyboard zoom, TalkBack labels, 2x text and EN/TR copy.

## Automated evidence

- `uv run --project server --locked python -m pytest -q server/tests/test_f51_floor_plan_http.py server/tests/test_f51_floor_plan_core.py`
  — 6 passed.
- `flutter test test/features/floor_plan/floor_plan_client_test.dart`
  — 4 passed across strict transport, retired callbacks, 600/1280 widths and
  2x text.
- Targeted Flutter analysis, Ruff, security policy, queue validation, progress
  validation, redacted gitleaks and merge-tree checks are required before PR.

## Honest remaining gates

- A floor-plan anchor is a safe read projection. Entity/device commands still
  require an explicit preview-confirm-readback path and are not implied here.
- Home Assistant area import and interactive editor gestures are separate work.
- Huawei MatePad, Samsung DeX, physical touch/keyboard/TalkBack and large-plan
  rendering performance remain manual hardware acceptance.
