# F04 same-device dispatch serialization (2026-10-03)

The prior rule path durably authorized a decision before calling Home Assistant,
but released the arbitration transaction before the provider send. A manual or
higher-priority decision could therefore replace the owner while the earlier
provider call was waiting. The earlier call could still write after the newer
owner, reverse the intended order, and then report a stale completion.

The repair adds a process-local, per-device dispatch registry scoped to the
canonical Core database. Decision admission, provider dispatch and durable
completion for one device use the same reentrant lock. The provider guard
revalidates the signed decision, effect token, owner, family, device, state and
both expiry times immediately before each provider boundary and again before
the Home Assistant receipt is committed. A stale or expired owner cannot enter
the provider callback. Existing Home Assistant command receipts remain the
replay authority; UNKNOWN results remain UNKNOWN and are never resent.

Fresh service objects that use the same canonical Core database share the
registry. Independent Core databases are isolated, and unrelated devices do
not block each other. A registry entry counts both holders and waiters and is
removed only after the last user releases it, so capacity cleanup cannot swap
the lock underneath a waiting same-device operation. The registry admits at
most the existing `MAX_DEVICES` number of concurrently active device entries.

This is deliberately a process-scoped exclusion boundary. The packaged Server
container enters through `python -m larenor_server.cli`, and that CLI fixes
Uvicorn to one worker. The implementation does not claim cross-process
serialization for unsupported multi-worker embeddings.

## Focused evidence

The new concurrency suite first failed against the unmodified production
sources: the manual provider callback entered while the rule callback was
held, and the arbitration service had no guarded-effect boundary. A second RED
case showed that two exact concurrent requests could both capture the same
authorized decision before either entered the guarded effect; the loser then
received suppression instead of the durable receipt. With the repair, nine
tests pass and cover:

- a held rule write followed by a same-device manual write, with exact provider
  order;
- manual and higher-priority replacement before provider admission;
- expiry before admission and expiry after durable Home Assistant intent;
- cancellation before provider admission, retaining the durable rejected
  outcome without a provider write;
- durable UNKNOWN classification and exact replay without another provider
  write;
- an exact concurrent request replay returning the same receipt after one
  provider write;
- a fresh service object sharing the same database/device lock while another
  device and an independently owned Core database continue; and
- saturation rejecting a new device without evicting a held lock or allowing a
  same-device waiter onto a replacement lock.

The existing focused suites pass separately to keep temporary SQLite storage
bounded on the constrained host: 2 rule-arbitration tests, 3 attribution tests
and 20 Home Assistant command tests. Total focused result: 34 passed, zero
failures, errors or skips. Ruff 0.14.14 passes the changed scope with the four
pre-existing Home Assistant `E702` findings excluded; the exact baseline and
changed-file scans contain the same four findings.

All provider behavior is synthetic and owned by the tests. No household Home
Assistant endpoint was contacted. These results are scoped software evidence;
required exact-source CI and final acceptance remain separate gates.

## Shared root proof and independent source review

Root integrated the frozen four-path repair, then reran34 actual concurrency/HA/attribution tests:34 passed, zero failure/error/skip (two existing TestClient deprecations), log SHA-256 `e1d3a2984d3d85c71357603c5ebe1e633030f8765edc24ddea37af3e84ae8486`. Two actual Flutter Client→normal Core lifetimes each satisfied exactlyone visible named pass with zero failure/error/skip; terminal log SHA-256 `11459d37a5dcfb0cec22c42e3f72f958506c7c8536a6c78d44eda45cabfd117f`. The strict helper/required aggregate focused gate passed20 tests/16subtests; this is local proof, not hosted CI.

Independent read-only source review was CLEAR for the documented packaged single-process scope. Reviewed production hashes: HA service `600d9e517f29b7aa48265510e1fe20e1062e6ae3c3525f53770306a8702bad9a`; arbitration service `31cacbc85e64819c15cd18942f5baf3d136662298e059231c39ea7012e383c22`; new concurrency test `443b16c1fa739578042ae83a2260301d343d793da192102202ebf07bf7d61c52`. Registry entries include both holders and waiters; every service retains the weak registry strongly; submit/complete/effect paths share the same reentrant lock. Signed ownership is rechecked before provider and durable receipt boundaries. Durable replay cannot resend. This does not prove multiprocess serialization or physical HA cancellation; uncertain provider outcomes remain UNKNOWN.

F04 implementation returns to awaiting CI. Full feature acceptance still requires F05 acceptance, registered exact-source named CI and final combined required checks; no accepted counter or main merge changes.
