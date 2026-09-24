# K07 versioned tablet profile Core contract

Status: **Core/API job complete; accepted as part of K07 closure**

## Scope

This first job adds the durable Core contract for publishing and reading one
versioned profile for an exact managed tablet. It does not add Client fetch or
apply behavior, and it does not change paired-remote or MQTT delivery code.

## RED

The new focused package initially failed all five tests: the strict publication
endpoint did not exist and the tablet fleet had no migration path from schema 1
to durable profile storage. The failures covered publication/read, optimistic
concurrency, exact-device authorization, tamper detection, restart persistence,
and legacy schema migration.

## GREEN guarantees

- An authenticated administrator publishes only to an active exact device with
  the current device revision and current profile revision. Device and profile
  revisions advance atomically in one immediate transaction.
- The digest is SHA-256 over the compact versioned Core/home/device/settings
  tuple. Unknown keys, non-integer versions, booleans in integer fields,
  malformed digests, stale revisions and overflow all fail closed.
- Only the active device's current account and session family can read its
  publication. Foreign accounts or session families receive no device details.
- Profile content is encrypted at rest. Its AEAD authority binds Core, home,
  device, revision, schema, digest and timestamps; digest, ciphertext or
  revision drift blocks live reads and server restart.
- Existing schema-1 tablet fleet databases migrate transactionally to schema 2.
  Once a durable publication exists, the legacy revision-only endpoint cannot
  advance policy without matching content.

Focused publication tests passed **5/5**. The grouped tablet fleet, policy,
rollout and paired-remote server package passed **27/27**. Ruff, compile,
security, queue, diff and commit-progress gates are recorded on the delivery
commit.

Client fetch/atomic apply and managed-device authority are now automated and
accepted with the full K07 chain. K07 is `done` at **29/125 (23.2%)** and
**0/63 (0.0%)**. Real broker deployment and physical-device acceptance remain
MANUAL.
