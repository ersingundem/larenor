# S08.8 member Core media catalog TDD evidence

This slice exposes the existing read-only Core catalog to every ready household
member without exposing installation management or archive-health endpoints.
S08.8 remains pending.

## Accepted behavior

- `/media/catalog/target` and `/media/catalog/search` require a ready current
  session. Both operations resolve the same single ready Jellyfin installation;
  ambiguity, replacement, revision drift, logout, or authority drift fails
  closed before publication.
- The Client uses only the member catalog endpoints. It validates the exact
  five-key integer-version target, pins installation, snapshot, and Jellyfin
  revisions, and rechecks the exact account/session plus route owner between
  target discovery and search. A retired owner starts no follow-up request.
- The authenticated Core home exposes the catalog to members while the music
  and archive administration entries remain administrator-only. The EN/TR
  catalog route fits 600 and 1200 tablet/DeX widths at 2x text scale.

## RED

Commit `c3d35382` proves that the initial member search accepted a selected
installation when two ready Jellyfin targets existed, issued search after its
route owner retired during target discovery, and accepted numeric `1.0` as the
integer schema version.

## GREEN

Commit `54d0a46b` binds every member gate to the unique canonical target, threads
the exact current account/session owner through both Client network awaits, and
requires an integer schema version.

Run from the branch head:

```text
uv run --project server pytest -q server/tests/test_media_archive_core_read.py server/tests/test_media_catalog_search.py
flutter test test/features/server/server_media_catalog_test.dart test/features/server/server_media_catalog_screen_test.dart
flutter analyze lib/features/server/media_catalog/data/server_media_catalog_api.dart lib/features/server/media_catalog/data/server_media_catalog_controller.dart test/features/server/server_media_catalog_test.dart test/features/server/server_media_catalog_screen_test.dart
python3 tool/execution_queue.py validate
```

The focused batches pass 25 Server and 18 Flutter tests. Scoped analysis,
security policy, queue validation, progress validation, and diff checks are
clean. Progress remains 26/125 and 0/63.
