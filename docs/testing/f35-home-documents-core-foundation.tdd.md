# F35 home documents Core foundation

This first F35 slice is based directly on `main` and adds an isolated Core
contract. It does not copy the open F34 inventory implementation or register an
HTTP route. Durable encrypted storage, bounded file upload, Paperless worker,
Client integration, delete/backup policy and full Client-to-Core E2E remain
dependent slices. F35 therefore remains open at **18/125** and **0/63**.

Exactly three acceptance criteria are delivered:

1. A strict versioned create command binds the exact Core, home, account
   revision, session family, library revision, inventory item and verified
   bounded-blob descriptor. Exact replay is idempotent; changed replay, stale
   revisions, foreign scope, unavailable references and capacity overflow fail
   closed.
2. OCR contributes only a dated evidence candidate and digest. It cannot create
   a warranty reminder. An explicit admin confirmation may accept or correct
   that date, records actor/time/correction state, increments both revisions and
   rejects stale, unauthorized or conflicting confirmation.
3. Search and due-reminder projections are bounded, deterministic and filtered
   by creator/admin/reader access. Public records contain blob metadata rather
   than file bytes or OCR text, and an account with no visible documents receives
   a zero projected revision so private library activity is not disclosed.

## TDD evidence

RED failed during collection because `larenor_server.home_documents` did not
exist. The focused tests then exercise exact replay and changed replay,
authority and reference rejection, OCR correction and stale confirmation,
private search, confirmed-only reminders, invalid dates and query bounds.
These are isolated software tests; they do not claim Paperless, durable storage,
Android, physical-device or production deployment acceptance.
