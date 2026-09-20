# S08.10 bounded-transfer event chain TDD evidence

20 September 2026. This Server-only slice closes three software acceptance
criteria without changing either progress counter.

## Closed criteria

1. Transfer acceptance and its completed or interrupted result are immutable
   snapshots carrying the same opaque `requestId` and trace identity.
2. `GET .../blob/transfers/events` exposes a monotonic bounded cursor and a
   stable chain identity derived for the authorized actor/resource view. A
   member cannot observe another actor or resource through rows, counts or a
   reusable global cursor.
3. Restart recovers an accepted operation as one interrupted result. A normal
   restart and an idempotent replay append no event. HMAC-authenticated event
   rows, chain head and current receipt agreement fail closed on alteration.

Existing receipts migrate once as `baseline` snapshots because their earlier
transition order cannot be reconstructed. New transfers append `accepted` and
`result` inside the same SQLite transactions that update their current receipt.
The endpoint returns metadata only; it never includes payload bytes, provider
paths, URLs, credentials or request bodies.

## RED/GREEN evidence

The RED commit first required distinct accepted/result reads, exact view
scoping, canonical cursor rejection and restart/replay stability. All three
tests failed on the missing event endpoint.

The GREEN implementation adds the authenticated append chain, migration,
strict response models and read-only API. The focused run is:

```text
PYTHONPATH=server python -m pytest -q \
  server/tests/test_bounded_transfer.py \
  server/tests/test_bounded_transfer_authority_order.py \
  server/tests/test_bounded_transfer_receipts.py \
  server/tests/test_bounded_blob_product_provider.py \
  server/tests/test_bounded_transfer_event_history.py
```

The suite covers existing framing, authorization order, quotas, durable
receipts and product blobs together with event transition, actor/resource
isolation, malformed queries, tamper detection, restart and replay behavior.

## Remaining boundary

The Android Client does not consume this event endpoint yet. Media-specific
protocols and physical SAF, Huawei tablet, DeX and LAN acceptance also remain
open. S08.10 therefore remains pending at queue 15/125 and selected features
0/63 until its complete evidence set passes review and CI.
