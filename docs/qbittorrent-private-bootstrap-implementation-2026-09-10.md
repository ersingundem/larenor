# Private qBittorrent endpoint and bootstrap executor — 10 September 2026

This slice establishes the worker-only boundary needed to configure the started
qBittorrent service without publishing its WebUI port or accepting a caller
address. It proves one numeric private endpoint from the exact managed-container
observation, then applies the fixed movie/TV categories and performs an
authenticated settings readback.

## Endpoint authority

- The proof requires the exact journal container ID, current qBittorrent binding,
  packaged stack hash, running state and sole Larenor control-network attachment.
- Only canonical RFC1918 IPv4 addresses and the packaged TCP/8080 web listener
  are accepted. The complete packaged listener set must also contain TCP and UDP
  6881 for torrent traffic.
- The connector opens one numeric IPv4 stream with no DNS, proxy, redirect,
  alternate target or caller-provided transport. Container, network or endpoint
  drift fails closed before the stream becomes authority.

## Bootstrap ordering

The private executor reconciles the exact `start_container` receipt, re-proves
the endpoint around every connection and repeats the caller's retained-authority
gate at six boundaries. It first idempotently creates or verifies only the
`movies` and `tv` categories, then opens a fresh proved stream and verifies the
pinned qBittorrent version, private API key, owned preferences and exact category
paths. Connections are closed on success, rejection and authority loss.

All errors use fixed codes and bounded, allowlisted step lists. A failure after a
possible category mutation is marked as an uncertain effect. Credentials, API
keys, addresses, raw HTTP, Docker observations and exception details are hidden
from result and error representations.

## Verification

Exact source `293481597ec231ef48af021752e1b69decb33eed` adds endpoint and
bootstrap executor tests for private-address validation, packaged listener
checks, numeric-only connection, journal reconciliation, six authority gates,
endpoint drift before and after effects, category/readback failures, closed
dependencies and secret-free diagnostics. The complete qBittorrent plus related
runtime, supervisor, execution and managed-container selection collected 354
tests and completed with 353 passing plus one existing macOS skip. `compileall`,
diff validation, repository security policy and gitleaks pass.

## Remaining boundary

This executor is worker-private infrastructure and is not yet dispatched by the
Core job. The next slice must add a readiness-bounded IPC/runtime operation and
persist a service-verification receipt. Disposable amd64/arm64 qBittorrent
startup, category/readback and restart persistence remain required before
`installAvailable` or S06.5 can close.
