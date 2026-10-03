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

## Client negative lifecycle evidence, 2026-10-03

`core_audit_checkpoint_lifecycle_test.dart` adds five focused production-path
regressions without changing the controller or store:

- a delayed normal audit response completed after account sign-out cannot
  republish verification or trusted state;
- route disposal prevents a delayed response from notifying or publishing;
- malformed JSON, an over-4096-byte record, an extra-key record and a backend
  read failure are rejected without replacing retained bytes;
- failures before a checkpoint write retain the previous record, while a
  write-then-error is treated as uncertain and only the subsequent strict
  readback exposes the new revision;
- a stale revision conflict and the JS-safe maximum revision reject rotation
  without modifying the current trusted record.

The exact private focused run passed 5 tests with zero failures or skips, and
scoped analysis was clean. Current exact-commit required CI still must execute
the named normal-Core runner. The checkpoint backend in this regression is an
in-memory fault boundary; it exercises the production codec, controller,
serialization and ownership guards but does not establish Android Keystore or
iOS Keychain behavior.

## Root shared-source execution and review

On base `bef70b4bca550a464fd6ccb2ec8822d69c4d5597`, root executed all five integrated Client negative regressions successfully, then the strict named normal-Core runner passed both pin/rotate and restart lifetimes: one visible named test per lifetime, zero failures/errors/skips. The four-file Flutter analysis was clean. Frozen review manifest `ee74908a11ed119cf0bb7b6b6b68af858fa69f0e9a7216c4491538323a8d18be` binds the five-regression source; independent review found no P1/P2 within this scoped software claim. Existing production guards passed without a product-code correction.

- `larenor-root-f20-shared-lifecycle-20261003.log`: SHA-256 `d9038fcba105b7c223cf272a578f1914d81042308110d31b4d8e58009e9fec5b`.
- `larenor-root-f20-named-required-20261003.log`: SHA-256 `6d6dadd4758ccb642185893460d2a9cbdff165f0580860ae6ce9cea9a2a360d9`.

Fault-boundary storage is not physical platform secure storage. Cancellation during an already-issued platform write remains uncertain until subsequent strict readback. Final exact-source required CI registration/result and acceptance dependencies remain open; this slice is not accepted or merged.
