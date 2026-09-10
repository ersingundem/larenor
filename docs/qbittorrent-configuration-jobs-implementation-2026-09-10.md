# Durable qBittorrent configuration jobs — 10 September 2026

This slice gives Larenor Core an authenticated, encrypted and restart-safe job
for the private qBittorrent configuration operation. It exposes job progress to
an administrator, but keeps product installation disabled until the required
container create/start ordering and native service acceptance are complete.

## Public boundary

- The administrator route is
  `/api/v1/admin/media/qbittorrent-configurations`. It provides capabilities,
  create, bounded list, get and optimistic-revision cancellation operations.
- A create request refers only to an exact successful preparation and
  inspection. It cannot choose a Docker endpoint, container payload, service,
  credential, API key or salt.
- Public records contain fixed lifecycle and error codes. Credentials,
  configuration bytes, worker details and host paths never enter the response.
- `installAvailable=false` remains invariant in both capabilities and jobs.

## Durable private boundary

- Core generates the qBittorrent credential, API key and PBKDF2 salt. The
  private payload and eventual journal-bound digest receipt use AES-GCM with
  row identity, actor, session family, source IDs, state, revision and
  timestamps bound as authenticated data.
- The schema has exact unique request/preparation constraints, source foreign
  keys, a bounded row count and a verified dispatch index. Startup rejects
  schema drift, invalid ciphertext, incoherent public state and orphaned or
  changed source plans.
- A private `0600`, owner-checked, no-follow process lock permits one dispatcher.
  A queued job is never retried after its durable state becomes `running`.
- Core checks the administrator session, Core/home context, preparation,
  inspection and packaged catalog before dispatch, during the worker gate and
  after the effect. Cancellation or authority loss after a possible effect is
  retained as `needs_attention` instead of being reported as a clean failure.
- The Server lifespan starts this dispatcher only when the separate installation
  worker is configured and waits for an in-flight receipt before shutdown.
  Runtime failures log one static code without exception or payload details.

## Verification

Source commit `9bf5f4092fecd8794200d214b7bb2dd6f5c0793e` adds 23 focused tests.
They cover encryption, idempotency, capability truth, real peer-UID Unix IPC,
automatic dispatch, graceful shutdown, secret-free logging, cancellation,
restart interruption, authority loss, uncertain effects, strict HTTP input and
fail-closed storage damage. The wider qBittorrent, installation, preparation,
inspection, runtime, Core and API-boundary selection collected and passed 263
tests. The four pinned `apksig 9.1.0` release-verifier tests also passed with
Homebrew JDK 17 selected. `compileall`, diff validation and gitleaks passed.

## Remaining acceptance boundary

The qBittorrent container must still be created and started only after this
configuration receipt, then exercised against a disposable real service on
both amd64 and arm64. Radarr, Sonarr, Seerr and Music Assistant automatic
mapping also remains open. S06.5 and `installAvailable` therefore remain open.
