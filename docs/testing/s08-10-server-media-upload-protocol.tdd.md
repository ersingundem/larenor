# S08.10 Server media upload protocol TDD evidence

## Source and acceptance slice

This slice derives from `docs/s08-10-integration-acceptance-2026-09-15.md`
and closes three Server-side guarantees on 20 September 2026:

1. document, image, audio, and video uploads use a closed media-type and
   payload-signature contract before encrypted persistence;
2. a rejected first upload creates neither an object nor an immutable upload
   journal row, and the same request identifier can be corrected safely; and
3. a rejected replacement preserves the current object, descriptor, service
   revision, digest, and upload journal.

This is independent of the pending Client checkpoint/event work and does not
depend on Android SAF preflight or Client status-language changes.

## RED and GREEN

| Stage | Commit or command | Result | Guarantee |
| --- | --- | --- | --- |
| RED | `2ff75e66` and `PYTHONPATH=server .../python -m pytest -q server/tests/test_bounded_media_upload_protocol.py ...` | Collection failed because `larenor_server.bounded_transfer.media_policy` did not exist. | The tests named the missing production boundary before implementation. |
| GREEN | `67ba5c4e` and the same focused 3-file pytest group | 19 passed. | The closed payload contract and both no-partial-mutation paths pass with the existing product-provider and authority-order regressions. |
| Coverage | `PYTHONPATH=server uv run --project server --locked --with coverage==7.10.7 coverage run --branch --source=larenor_server.bounded_transfer.media_policy,larenor_server.bounded_transfer.product_store -m pytest -q ...` | 19 passed; 82% branch-aware coverage across the two production modules. | The new boundary and its persistence integration exceed the slice coverage floor. |
| Static | `python3 -m compileall -q server/larenor_server/bounded_transfer server/tests/test_bounded_media_upload_protocol.py` and `git diff --check` | Passed. | Python sources compile and the patch has no whitespace errors. |

## Scope boundary

The Server now validates new bounded product uploads before any database
mutation. Existing encrypted objects are not rewritten. Range/resume, the
remaining Client receipt/event integration, and physical SAF/LAN acceptance
remain separate S08.10 work. Queue and selected-feature counters remain
`15/125` and `0/63` because this slice alone does not close S08.10.
