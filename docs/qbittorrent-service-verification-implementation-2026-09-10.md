# qBittorrent verified service dispatch — 10 September 2026

This slice binds the worker-private qBittorrent bootstrap to the ordered
configuration, container and durable Core job path. A new job can report
success only after the owned configuration is installed, the exact managed
container is started, its fixed categories are present and an authenticated
readback verifies the pinned service identity and settings.

## Readiness and authority

- The executor retries only a refused initial read-only TCP connection while
  the common deadline remains open.
- Every readiness attempt rechecks the caller's retained authority, freshly
  inspects the same journal-bound container and proves the same private numeric
  endpoint. Endpoint drift ends the operation with a fixed error.
- Category mutation and authenticated readback still use separate fresh proved
  streams. There is no DNS, proxy, redirect, caller-selected destination or
  alternate endpoint.

## Runtime, IPC and durable state

The installation worker now runs the private bootstrap immediately after the
ordered configuration/create/start effects. Bootstrap failures are projected
to closed qBittorrent service, timeout or authority codes and are marked as an
uncertain effect because the container is already running.

The UID-authenticated installation IPC accepts success only when its combined
receipt contains `qbittorrent_service_verified`. Core persists this fact inside
the encrypted job payload and exposes only `serviceState=verified`. Existing
configuration-only and container-started receipts remain readable, but never
claim service verification. New unverified results become `needs_attention`.

## Verification

Exact code source `a1e3bb6a1b012c1b6f9a34bfd54ab447bd81c3ef` adds readiness,
endpoint-drift, IPC, runtime error projection, durable job and legacy-receipt
regressions. The five focused bootstrap/IPC/job/runtime/supervisor files complete
with 130 passing and one existing macOS-only skip. With the pinned official
apksig 9.1.0 jar and JDK 17, the complete Server collection completes with
4,831 passing and 13 platform skips. Repository security policy, compileall,
queue validation, diff validation and gitleaks pass.

## Remaining boundary

`installAvailable` remains false. Disposable amd64 and arm64 qBittorrent
startup, category/readback and restart-persistence receipts must pass on this
exact source. Radarr, Sonarr, Seerr and Music Assistant still need their owned
private bootstrap and automatic cross-service wiring before S06.5 closes.
