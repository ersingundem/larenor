# S08.11 Core vault v3 wire compatibility

This slice keeps the encrypted Server vault envelope at version 1 and adds
snapshot version 3 for dashboard ownership. It does not change backup capture,
restore transactions, or UI behavior.

## Compatibility contract

| Snapshot | Dashboard ownership | Result |
| --- | --- | --- |
| v2 | No `dashboardOwner` | Accepted legacy wire format |
| v2 | Any `dashboardOwner` | Rejected |
| v3 | No dashboard and no owner | Accepted for other backup groups |
| v3 | Dashboard with `directLocal` owner only | Accepted |
| v3 | Dashboard with `verifiedCore` and exact scope | Accepted |
| v3 | Dashboard or owner present alone | Rejected |

The `verifiedCore` scope contains exactly `coreId`, `homeId`, and `userId`.
Both Core identities are 32 lowercase hexadecimal characters. The user ID is
non-empty, contains no ASCII control characters, and is at most 128 Dart UTF-16
code units. `directLocal` carries no scope. Unknown owner fields, sources, and
scope fields fail closed with the fixed `invalid_request` code.

The Server validates the envelope, privacy disclosure, owner, and scope before
encrypting the document. It continues to treat the evolving dashboard payload
as opaque; the Client `BackupSnapshot` parser validates that payload before
preview or apply. `ServerVault` admits only snapshot versions 2 and 3, then
delegates the complete snapshot to that parser.

`contracts/server-vault-dashboard-owner.v3.json` is the secret-free shared
fixture for the Python vault boundary and the Dart backup/parser integration.

## TDD evidence

- RED `da0fff76`: v3 local/Core owners and non-dashboard v3 documents were
  rejected while adversarial substitutions already failed closed.
- GREEN `74359bee`: the Python boundary accepts the supported v3 forms and
  rejects version, presence, source, field, identity, control-character, and
  UTF-16 length substitutions.
- Dart wire `cd5191cd`: `ServerVault` admits v2/v3 only and keeps malformed or
  future versions behind `invalid_response`.

Focused validation:

```text
PYTHONPATH=server .../pytest server/tests/test_storage.py -q  # 39 passed
flutter test test/features/server/server_account_test.dart   # 25 passed
```

The S08.11 queue node remains pending. Cross-process restart, portable restore,
logout, and exact Core authority acceptance remain in the owning integration
slice.
