# F35 durable home documents Core and Android Client

This slice connects the tablet-first document library to one durable Larenor
Core authority. It reuses the existing bounded product-blob protocol and the
verified Core account; it introduces no second URL, token or state owner.

## Three acceptance criteria

1. **Durable private Core contract.** Core registers authenticated create,
   confirmation, search and reminder endpoints bound to the exact Core, home,
   account revision and session family. Documents and idempotency receipts are
   stored as one bounded AES-GCM protected SQLite state and survive a Core
   restart. Scope, revision, malformed query and storage integrity failures are
   closed.
2. **Bounded upload and verified publication.** The Client resolves an exact
   writable home resource from one snapshot, reads only PDF/JPEG/PNG through
   Android's bounded file handle and reuses the 256 KiB product-blob upload
   protocol. Resource, ACL, account and service revisions plus digest, MIME and
   length must match. Create and optional warranty confirmation publish only
   after exact search/reminder readback; late route or lifecycle results are
   discarded.
3. **Tablet route and discoverable entry.** The verified-Core shell exposes a
   48dp Documents action and an exact route-owned runtime. The existing
   Cupertino surface remains usable in English and Turkish at 600/1200 logical
   pixels and 2x text, with keyboard traversal, TalkBack labels and live status.
   Account, container, endpoint, route, window focus or lifecycle drift retires
   both HTTP clients and clears private projections.

## TDD evidence

- RED `babde62e`: Core registration and durable restart tests failed because
  `CoreServices.home_documents` did not exist.
- GREEN `857eb9ea`: the encrypted schema/repository and HTTP router made the
  Core contract plus restart suite pass.
- RED `aea95763`: Client HTTP and bounded-upload tests failed because the
  production adapter did not exist.
- GREEN `db8777ed`: real HTTP, bounded upload, route ownership and shell entry
  pass the focused Server and Flutter suites.

Validated commands:

- `uv run --project server --locked python -m pytest -q server/tests/test_home_documents_contract.py server/tests/test_home_documents_http.py` — 5 passed.
- `flutter test test/features/home_documents test/features/home_scope/core_home_status_tablet_accessibility_test.dart` — 16 passed.
- Focused `flutter analyze` — no issues.

F35 remains at the current main counters, **21/125** and **0/63**. Physical
Huawei/DeX document-provider, real OCR provider and printed warranty workflow
are manual or dependent acceptance gates; this slice does not claim them.
