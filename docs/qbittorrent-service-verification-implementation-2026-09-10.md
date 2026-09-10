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

PR41 then exercised this path against the pinned LinuxServer qBittorrent
5.2.3 image. The first native runs exposed two production-only assumptions:
Docker network inspect legitimately contains the attached managed endpoint,
and qBittorrent accepts an API key only in its exact `qbt_` plus 28 character
format. The final readback also proved that disabling WebUI UPnP does not
disable peer-port forwarding, so the owned config now independently sets
`Network/PortForwardingEnabled=false`. The response parser accepts qBittorrent's
bounded `text/plain` error body before classifying its status, while success
payloads still require the expected media type.

Exact PR head `f00a869d4f0fcbddf70fecbb99bb1bb96553d7ff` passed the
[two-architecture native run](https://github.com/ersingundem/larenor/actions/runs/34437420807).
Both downloaded receipts were independently verified against merge source
`8cf7257d63447f1441f2ae66f9fd8a477e7f341a`; amd64 and arm64 each proved
configuration, container startup, Bearer authentication, two persistent
categories, one restart and post-restart readback. The latest related local
package completed with 289 passing tests.

## Remaining boundary

`installAvailable` remains false. Radarr, Sonarr, Seerr and Music Assistant
still need their owned private bootstrap and automatic cross-service wiring
before S06.5 closes.
