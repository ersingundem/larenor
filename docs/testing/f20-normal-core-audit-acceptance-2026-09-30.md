# F20 normal Core audit acceptance — 2026-09-30

## Production path exercised

`server/tests/support/f20_flutter_acceptance.py` starts the ordinary Core app
over loopback TCP and runs the real Flutter account, Core-audit controller, API
and checkpoint store contract. The only test-specific part is a bounded file
backend standing in for the platform secure-storage plugin so that the retained
device checkpoint crosses a fresh Flutter process. Core, authentication, HTTP,
audit journal and verification are not injected.

The first Client process verifies the complete journal, pins the signed Core
checkpoint, causes a real audited administrator mutation, compares the retained
checkpoint as a prefix, and rotates the device checkpoint after explicit
comparison. The runner then stops Core and starts a fresh normal Core plus a
fresh Flutter process over the same encrypted database and retained checkpoint.
The Client compares the rotated checkpoint exactly, appends another real audit
event and verifies that the older retained checkpoint remains a valid prefix.

After the clean Client/restart path finishes, the harness changes the actor in
one retained `admin_audit` row without changing the authenticated chain. A new
normal Core startup must fail with `core_audit_storage_invalid`. The runner
compares the complete SQLite logical dump before and after the failed startup
and requires it to be unchanged; it also requires that no bootstrap credential
was recreated. This proves detection without a silent reset.

## Named command

```text
server/.venv/bin/python server/tests/support/f20_flutter_acceptance.py
flutter test --no-pub test/features/core_audit/core_audit_api_test.dart
server/.venv/bin/pytest -q server/tests/test_admin.py::test_audit_static_redacted_ordered_paginated_and_bounded server/tests/test_core_context.py
flutter analyze --no-pub lib/features/core_audit lib/features/server/data/larenor_server_api.dart test/features/core_audit/core_audit_api_test.dart test/features/core_audit/core_audit_normal_core_test.dart
```

Focused files:

- `server/tests/support/f20_flutter_acceptance.py`
- `test/features/core_audit/core_audit_api_test.dart`
- `test/features/core_audit/core_audit_normal_core_test.dart`

## Security boundary

The retained checkpoint detects alteration, deletion, reordering and rollback
when the Client checkpoint remains outside the Core database. It does not prove
why a physical event occurred and cannot provide absolute immutability against
an attacker who controls the Core database, Core HMAC key and the Client secure
checkpoint together. The acceptance uses an isolated synthetic account and no
household devices, services or credentials.
