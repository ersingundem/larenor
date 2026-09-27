# F38 encrypted memory albums Core slice

Status: encrypted selection storage is implemented; F38 remains `pending` and
no progress counter change is claimed.

## Three accepted criteria

1. A personal album is visible only to its owner. A shared album is visible
   only to its exact stored members. Every read and update remains bound to the
   current account, session family, Core, and home authority; stale album or
   Immich service revisions fail closed.
2. Titles, membership, source-album references, asset UUIDs, and source
   integrity tags are AES-GCM encrypted at rest. The clear SQLite envelope holds
   only scope and revision fields needed for bounded lookup. Its HMAC record
   anchor detects owner, scope, provider binding, revision, payload hash, or
   timestamp tampering before any private manifest is returned.
3. Each home is limited to 64 tablet albums, each album to 250 unique assets,
   and sharing to 32 unique members including the owner. An exact Immich asset
   deletion removes every matching selection for that service revision in one
   transaction, advances each changed album revision, and is idempotent.

## Evidence and remaining work

Fourteen focused F38 tests cover the confined Immich adapter and encrypted
album store, including personal/shared reads, stale writes, encrypted raw rows,
source deletion, idempotent cleanup, and tamper rejection. The current-members
resolver, authenticated HTTP routes, asset-integrity reconciliation, backup and
restore verification, Android tablet picker, and real Immich acceptance remain
open. Originals and provider credentials never enter this store.
