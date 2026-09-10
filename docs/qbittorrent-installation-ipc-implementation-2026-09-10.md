# qBittorrent installation IPC evidence — 10 September 2026

This slice carries one private qBittorrent configuration request from Larenor
Core to the already separate mutating installation worker. It does not add a
public HTTP route and does not make installation available.

## Closed contract

- The request contains only a 32-character job identity, the complete packaged
  media-stack plan, and a frozen private model holding the generated credential,
  API key and 16-byte PBKDF2 salt.
- Core verifies the current packaged plan and its live authority gate before the
  Unix exchange. The worker repeats strict JSON/model/catalog validation before
  private values reach the runtime.
- Socket ownership, peer UID, packet bounds and request correlation use the same
  installation-worker channel as managed container and Jellyfin bootstrap work.
- The worker passes the job identity into the retained-daemon supervisor. The
  runtime accepts only an exact lowercase object ID before resolving the current
  journal-owned qBittorrent appdata volume.
- A successful response contains only resource, operation and journal IDs,
  revision, generated volume name, configuration digest and a fixed state.
  Credentials, API key, salt and configuration bytes never enter the receipt.
- Worker failures are reduced to five static execution categories. Authority
  loss after a completed exchange is marked as an uncertain effect.

## Verification

The change adds 14 focused IPC tests covering success, pre/post-effect authority
loss, uncertain worker failure, strict client inputs, unvalidated model copies,
job binding and invalid receipts. The wider qBittorrent, Engine-stdin,
installation runtime/supervisor and volume suite collected 418 tests and passed
417 with one existing macOS-only skip. `compileall`, diff validation, execution
queue validation and gitleaks also passed locally at source commit
`0983c28d87f06d891a5023ea14db3a54881281d3`.

## Remaining acceptance boundary

The encrypted durable Core job, explicit ordering before qBittorrent container
create/start, cancellation propagation during the bounded worker call, and real
amd64/arm64 qBittorrent acceptance remain open. `installAvailable=false` and the
S06.5 completion count therefore remain unchanged.
