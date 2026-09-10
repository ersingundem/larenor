# Ordered qBittorrent configuration and container start — 10 September 2026

This slice joins the private qBittorrent configuration effect to its managed
container execution. A durable Core job can succeed only after the owned
configuration has been installed and the exact qBittorrent container has been
created and started from fresh journal-bound resource proofs.

## Closed execution path

- Core dispatches one `install_configured_qbittorrent` operation over the
  owner/peer-UID checked installation socket. Public callers still cannot send
  an image, Docker endpoint, mount, network, container body or credential.
- The worker revalidates the complete packaged stack, installs or reconciles the
  qBittorrent config receipt first, and only then derives the fixed
  `create_container` and `start_container` steps.
- The qBittorrent binding has no published ports. It mounts its owned `/config`
  volume and the one approved shared library at writable `/data`, both with
  `NoCopy=true`; any extra, missing or reordered binding data fails closed.
- Configuration, binding construction, create and start share the same retained
  daemon lease, native worker thread, deadline and repeated authority gate.
- Core stores the configuration and container journal receipt together in its
  authenticated encrypted job payload. Public state exposes only
  `containerState=container_started`. Configuration-only receipts created by
  the preceding release remain readable and truthfully return no container
  state.

## Failure boundary

A configuration failure prevents container creation. An invalid worker result,
lost response, post-effect cancellation or authority change becomes
`needs_attention` when an effect may have occurred. Interrupted running work is
not retried. Credentials, API keys, salts, configuration bytes, container IDs,
host paths and exception text do not enter public responses or logs.

## Verification

Source commit `da879f31877f098dbdc60d677d163781f43c0107` adds or extends 15 production
and test files. The focused Core, IPC, runtime, supervisor, execution, binding,
resource-proof and API selection collected 229 tests and completed with 228
passing plus one existing macOS-only skip. This includes a real Unix-socket
Core-to-worker lifecycle, exact `configure → binding/create → binding/start`
ordering, same-thread supervisor gates, legacy encrypted receipt readback,
secret-free failure handling and strict public-state coherence. `compileall`,
diff validation and the execution-queue validator also pass.

Exact PR head `729eb1e9bebc29c9ee73cdf2d3bda50b89b72076` then passed the
Server, Android analyze, debug APK, API 35 emulator E2E, dependency, platform
policy and secret-scan jobs. Source-bound characterization passed on amd64 and
arm64. PR 38 merged as `307f8dc0ff575171ac8a6972e5974dc59397757d`.

## Remaining acceptance boundary

This source has not started qBittorrent against the disposable amd64 and arm64
CI daemons. Authenticated service readback, category verification, restart data
persistence and automatically wired Radarr/Sonarr connections still require
native evidence. `installAvailable=false`, S06.5 and the global completion
counter therefore remain open.
