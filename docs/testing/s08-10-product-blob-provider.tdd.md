# S08.10 product blob provider TDD evidence

## Source and journey

This slice derives from `docs/s08-10-integration-acceptance-2026-09-15.md`.
A write-authorized household member can attach or replace a small document or
media object on a Home resource, then a read-authorized tablet can retrieve the
same bytes through the existing verified transfer without exposing a server
path or storing plaintext.

## RED and GREEN

| Stage | Command | Result | Guarantee |
| --- | --- | --- | --- |
| RED | `PYTHONPATH=server uv run --project server --locked python -m pytest -q server/tests/test_bounded_blob_product_provider.py -x` | Expected failure: upload route returned `invalid_request` before implementation. | The acceptance journey exercised the missing public behavior. |
| RED | `... pytest ...::test_wall_clock_rollback_cannot_corrupt_a_replacement` | Expected failure: replacement persisted `updatedAt` before `createdAt`. | Clock rollback regression was reproduced against the implementation. |
| GREEN | `... pytest -q server/tests/test_bounded_blob_product_provider.py` | 13 passed. | Upload, replacement, replay, restart, authorization, bounds, revision conflicts, cascade deletion, encryption/tamper and clock rollback behave as specified. |
| Regression | bounded transfer/product group | 45 passed. | Existing framed downloads, authority order and durable receipts remain compatible. |
| Regression | API boundary/Home resource group | 77 passed. | Binary boundary changes preserve JSON limits and registry lifecycle behavior. |
| Static | `python3 -m compileall -q server/larenor_server` and `git diff --check` | Passed. | Python sources compile and the patch has no whitespace errors. |
| Coverage | `uv run --with coverage==7.10.7 coverage run --branch --source=...` | 80% branch-aware total for `product_store.py` and `blob_schema.py`. | New persistence and schema code meets the slice coverage threshold. |

## Scope boundary

The Server provides the production object store, upload receipt, descriptor and
download provider. Android source selection, descriptor-driven replacement,
upload UI, physical SAF/LAN evidence, range/resume and larger media protocols
remain separate acceptance work. Queue and selected-feature counters therefore
do not change in this slice.
