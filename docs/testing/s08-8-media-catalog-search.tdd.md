# S08.8 central media catalog search

This slice moves one Jellyfin catalog/search read behind the authenticated
Larenor Core boundary. It does not close `S08.8`; queue progress remains
**26/125** and selected-feature progress remains **0/63**.

## Three accepted behaviors

1. **Core search contract.** An administrator searches only a freshly verified
   managed Jellyfin archive snapshot. The request is bound to the exact
   installation and snapshot revisions, uses bounded body fields, returns at
   most 50 deterministic playable items and rechecks session and source
   authority after the private worker completes.
2. **Strict Client adapter.** The Client performs the existing Core authority
   handshake before search, keeps the query out of the URL, and accepts only
   exact schema, identity, revision, pagination and media-key fields. URLs,
   headers, provider credentials and playback tokens have no result field;
   unknown or secret-bearing response fields fail closed.
3. **Lifecycle retirement.** The controller binds one search to the exact
   account generation, session instance and route callback. Logout, account
   replacement, route retirement or disposal prevents a delayed result or
   failure from being published.

The Core route is deliberately administrator-only in this slice. The later
catalog UI must define and test its member access policy before S08.8 can close.

## TDD evidence

RED commit `test(s08.8): specify central media catalog search` added the Core
endpoint, strict Client and delayed-account-loss expectations. Core returned
404 for all 11 focused scenarios and the Flutter test failed because the typed
adapter and controller did not exist. The following GREEN commit implements
the three behaviors.

Focused verification:

```text
PYTHONPATH=server /Users/ersingundem/oikos/server/.venv/bin/python -m pytest -q \
  server/tests/test_media_archive_core_read.py \
  server/tests/test_media_archive_client_authority.py \
  server/tests/test_media_archive_ingestion.py \
  server/tests/test_media_catalog_search.py
# 34 passed

flutter test test/features/server/server_media_catalog_test.dart
# 4 passed

flutter analyze lib/features/server/media_catalog \
  test/features/server/server_media_catalog_test.dart
# No issues found
```

## Remaining S08.8 acceptance

The catalog has no tablet route yet and does not dispatch playback. Member
policy, browse pagination UI, remaining direct Jellyfin surfaces, explicit
legacy provider/player approval, integrated same-URL replacement/logout E2E,
independent review and exact-head CI remain open. The acceptance item and both
progress counters therefore stay unchanged.
