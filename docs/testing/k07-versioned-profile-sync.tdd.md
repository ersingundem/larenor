# K07 versioned managed-tablet profile synchronization

Status: **software slice ready; K07 remains pending**

This slice replaces the revision-only `syncProfile` placeholder with one
Core-published document and one bounded Client application path. It does not
claim physical Huawei/DeX, managed-device identity, or live Mosquitto
acceptance.

## Three acceptance jobs

1. **Durable Core publication.** An authenticated administrator publishes a
   strict fullscreen and idle-timeout document for one exact active tablet.
   Core binds its digest to Core, home and device identity, advances device and
   desired-profile revisions in one compare-and-swap transaction, encrypts the
   row at rest, and rejects stale, foreign, revoked or tampered reads.
2. **Bounded command and readback.** `syncProfile` runs only through the
   current paired-tablet lease. Client reads the exact publication through its
   current ready account session, recomputes the canonical digest, rejects a
   foreign device or revision, and obtains the installed Client version from
   the same native telemetry lease.
3. **Atomic local activation.** Client stores one validated profile document,
   activates fullscreen and second-precise idle timing before acknowledging
   the profile through the existing heartbeat, and rolls storage and providers
   back if lifecycle or account authority retires during activation. While a
   managed document is active, local display controls cannot silently override
   it. The durable envelope contains only a SHA-256 authority fingerprint and
   becomes effective after the current endpoint, account, device, pairing and
   enrollment revision match secure storage. Logout, replacement and revoke
   clear effective policy without exposing those identifiers in preferences.
   Foreign rollback targets are cleared rather than reactivated, and a command
   deadline retires its native lease before late work can persist or heartbeat.

## Verification

- Core profile publication, tablet fleet and rollout packages: **19 passed**.
- Managed profile store, native source/runtime, tablet API, window profile and
  idle gate packages: **109 passed**. The widget acceptance checks the exact
  29.999-second/30.000-second ambient boundary.
- Focused Dart analysis, Ruff 0.14.10 and diff checks passed.

K07 remains `pending`, so queue and selected-feature counters stay at
**26/125 (20.8%)** and **0/63 (0.0%)**. Trusted native device identity, live
TLS Mosquitto ACL acceptance and physical Huawei/DeX behavior are still
required before the queue item can close.
