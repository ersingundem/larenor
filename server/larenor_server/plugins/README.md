# S06: internal component catalog and provisioning plans

The delivered offline slice, 5 September 2026, consists of
[`models.py`](models.py), [`catalog.py`](catalog.py), and
[`packagedcatalog.json`](packagedcatalog.json). It validates six immutable
component manifests and calculates typed, deterministic requirements plans.
All six records have `installable: false`. This is not evidence that any image
has been started, installed on CasaOS, or tested with a physical player.

The product boundary is **one Larenor Server installation and account**, with
the media components provisioned and connected internally. Users manage media
settings through Larenor, without separately installing these applications or
copying their URLs/API keys. `managed_service` describes the five internally
managed media components; `internal_engine` identifies Music Assistant as the
Larenor music engine. Neither role means an independent user installation.
Per-component plans are internal building blocks for a later complete-stack
preview and provisioning job. Existing external S05 connections remain an
optional compatibility path. The job/worker sections below are design proposals;
API persistence and worker implementation have separate tests and evidence.

The scope comes from the [Client/Server plan](../../../docs/server-client-architecture-2026-09-05.md#eklenti-ve-casaos-yönetimi):
a versioned catalog, reviewable installation plans, persistent jobs, and a
separate bounded Linux worker. The initial catalog targets Jellyfin, Seerr,
Sonarr, Radarr, qBittorrent, and Music Assistant. Provisioning and automatic
interconnection still require a verified worker and bootstrap adapters.

## Delivered offline contract and verification

`load_catalog(raw: bytes | None = None) -> Catalog` reads the bounded packaged
resource, or validates supplied bytes against the same compiled package pin.
Duplicate keys, unknown fields, noncanonical numeric types, invalid privileges,
and different content fail with static errors. Whitespace and object-key order
do not change its digest. Nested model data is frozen and uses immutable tuples.

`plan(entry, settings: dict, platform: str) -> InstallPlan` has no filesystem,
network, host-inspection, or mutation side effects. It validates the entry again
against its compiled manifest pin, normalizes every setting (including defaults
and nullable library selections) in alphabetical order, and hashes the complete
result except `planHash` itself. `verify_plan(value, catalog) -> InstallPlan`
recalculates all effects from the worker's already loaded catalog; recomputing a
hash over altered ports, mounts, images, or privileges cannot authorize them.
Static failures are `catalog_invalid`, `catalog_digest_mismatch`,
`catalog_entry_untrusted`, `invalid_settings`, `unsupported_platform`, and
`plan_untrusted`.

Both `linux/amd64` and `linux/arm64` are pinned per component. On 5 September,
anonymous GHCR index manifests, platform manifests, and image configuration
blobs were fetched and their SHA-256 hashes matched the registry digests.
Platform declarations, version labels, public release tags, and the linked
licenses were checked. Image layers were not downloaded or executed. These
checks do not claim signature verification, reproducible builds, or a complete
dependency-license audit. `sourceRevision` records the referenced upstream
release or LinuxServer recipe revision, not an inferred build attestation.

| Component | Selected application / image tag | Distribution and license source |
| --- | --- | --- |
| Jellyfin | `10.11.11` / `10.11.11` | [Official image](https://jellyfin.org/docs/general/installation/container/), [GPL 2 license](https://github.com/jellyfin/jellyfin/blob/v10.11.11/LICENSE) |
| Seerr | `3.4.1` / `v3.4.1` | [Official image](https://docs.seerr.dev/getting-started/docker/), [MIT](https://github.com/seerr-team/seerr/blob/v3.4.1/LICENSE) |
| Sonarr | `4.0.19.2979` / `4.0.19.2979-ls323` | [LinuxServer recipe](https://github.com/linuxserver/docker-sonarr/tree/4.0.19.2979-ls323), [upstream GPL 3](https://github.com/Sonarr/Sonarr/blob/v4.0.19.2979/LICENSE.md) |
| Radarr | `6.3.0.10514` / `6.3.0.10514-ls314` | [LinuxServer recipe](https://github.com/linuxserver/docker-radarr/tree/6.3.0.10514-ls314), [upstream GPL 3](https://github.com/Radarr/Radarr/blob/v6.3.0.10514/LICENSE) |
| qBittorrent | `5.2.3` / `5.2.3_v2.0.14-ls474` | [LinuxServer recipe](https://github.com/linuxserver/docker-qbittorrent/tree/5.2.3_v2.0.14-ls474), [upstream source/binary license and OpenSSL exception](https://github.com/qbittorrent/qBittorrent/blob/release-5.2.3/COPYING) |
| Music Assistant | `2.10.2` / `2.10.2` | [Official installation](https://www.music-assistant.io/installation/), [Apache 2](https://github.com/music-assistant/server/blob/2.10.2/LICENSE) |

The catalog records upstream and distribution licenses separately. LinuxServer
recipe/image license metadata is `GPL-3.0-only`; this does not replace the
application's own licensing. qBittorrent's license text distinguishes GPLv2+
source from GPLv3+ binary assets and includes an OpenSSL exception.

Storage settings are opaque policy root IDs, never arbitrary host paths. App
data uses `<instance>/config`, Jellyfin also uses `<instance>/cache`, Seerr maps
to `/app/config`, and Music Assistant maps `<instance>/data` to `/data`.
Jellyfin/MA optional media mounts are read-only. Sonarr/Radarr/qBittorrent share
one approved writable library root at `/data`, allowing bootstrap to configure
consistent download/library paths without separate mounts breaking hardlinks.
The future worker must check root purpose, ownership, free space, symlink
boundaries, and existing resources before any mutation.

Default web ports are Jellyfin 8096, Seerr 5055, Sonarr 8989, Radarr 7878, and
qBittorrent 8080. qBittorrent's peer port is 6881 TCP/UDP. Changing its WebUI or
peer port changes both the published and container ports plus the corresponding
`WEBUI_PORT` or `TORRENTING_PORT` setting. Other bridge web-port settings change
only the published port. Bindings explicitly request `0.0.0.0`; host policy and
firewall review remain required. These preliminary per-component bindings are
**not an approved integrated-stack exposure policy**. The stack planner must
put control/bootstrap APIs on private service DNS/networking or loopback and
expose only reviewed playback/discovery/peer traffic and the Larenor entrypoint.
In particular, Jellyfin/Seerr/MA first-user setup must never be exposed to the
LAN while the worker is creating internal accounts. Existing immutable plans
must not be enabled unchanged. No firewall or router action occurs here.

All plans drop all capabilities and require no-new-privileges. Five use UID/GID
1000; LinuxServer's [documented non-root mode](https://docs.linuxserver.io/misc/non-root/)
also needs an executable `/run` tmpfs owned by that UID/GID. MA preserves the
existing package's root UID, host networking, and only `NET_BIND_SERVICE` for
[AirPlay PTP UDP 319/320](https://github.com/music-assistant/server/blob/2.10.2/music_assistant/providers/airplay/README.md).
Its 8095 web and 8097 stream listeners are requirements, not Docker published
ports; additional receiver ports can be dynamic. Host networking, playback,
HomePod synchronization, and physical-device behavior remain unverified.
Memory/CPU/PID/disk values are proposed Larenor resource budgets, not measured
upstream minima or successful runtime evidence.

The 99 offline tests cover schema and pin tampering, strict types, both
architectures for all entries, deterministic hashes, effect rederivation,
storage isolation, port/environment coupling, MA permissions, and absence of
plan I/O. The scoped run covered 318 statements and 78 branches in `catalog.py`
and `models.py` at 100%; it is not a worker/container acceptance result.
The built Python wheel was also inspected and extracted: its packaged catalog
loads with the same digest and produces all six arm64 plans. No application
image build or container execution was involved in that packaging check.

## Integration research at the selected versions

Music Assistant's [2.10.2 README](https://github.com/music-assistant/server/blob/2.10.2/README.md)
supports its Home Assistant app and Docker image. It explicitly does not ship a
plain PyPI server package: Python 3.14+, FFmpeg, native libraries and receiver
binaries are required. Its pinned Python dependencies also conflict with the
current Python 3.12 Larenor API environment. Consequently, use the official
digest-pinned image as a supervised **internal component** of the one Larenor
installation; embedding its Python object inside the API process is not an
upstream-supported runtime contract. This is an architecture recommendation
from source review, not a verified implementation.

The [2.10.2 web controller](https://github.com/music-assistant/server/blob/2.10.2/music_assistant/controllers/webserver/controller.py)
has `POST /setup` for a first internal administrator, `GET /info`, a configurable
web bind address, and its `/api` command interface. The
[auth manager](https://github.com/music-assistant/server/blob/2.10.2/music_assistant/controllers/webserver/auth.py)
can generate integration tokens through `auth/token/create`; these expire after
one year and do not renew on use. A future adapter must privately generate,
store and rotate engine credentials, expose only allowlisted Larenor actions,
and enforce current Larenor role/session scope. It must not give a shared engine
administrator token to the Client or implement an unrestricted command proxy.

Jellyfin's [versioned startup controller](https://github.com/jellyfin/jellyfin/blob/v10.11.11/Jellyfin.Api/Controllers/StartupController.cs)
can configure its first user and complete setup over an isolated control API.
Seerr's [versioned Jellyfin login route](https://github.com/seerr-team/seerr/blob/v3.4.1/server/routes/auth.ts)
can use that generated administrator, create its own initial administrator and
Jellyfin API key, then persist its Jellyfin connection. Its versioned settings
routes can register Sonarr/Radarr and complete initialization. These are real
upstream seams for automatic wiring, but are not atomic or generally idempotent:
the Larenor worker needs intent/receipt reconciliation and must refuse to adopt
an already configured, unowned application.

Additional versioned bootstrap seams:

| Link | Verified mechanism; remaining adapter responsibility |
| --- | --- |
| Sonarr/Radarr → qBittorrent | Their provider APIs expose `downloadclient/schema`, `downloadclient/test` and creation/update; use returned schema IDs with fixed allowlisted fields and private generated credentials. [Sonarr controller](https://github.com/Sonarr/Sonarr/blob/v4.0.19.2979/src/Sonarr.Api.V3/ProviderControllerBase.cs), [Radarr qBittorrent settings](https://github.com/Radarr/Radarr/blob/v6.3.0.10514/src/NzbDrone.Core/Download/Clients/QBittorrent/QBittorrentSettings.cs). |
| Private Arr API key | The configuration provider reads or generates its persisted `ApiKey`; an owned, fresh configuration can be prepared privately, followed by authenticated health checks. Do not expose a generic file editor or accept Client-supplied XML. [Sonarr configuration provider](https://github.com/Sonarr/Sonarr/blob/v4.0.19.2979/src/NzbDrone.Core/Configuration/ConfigFileProvider.cs). |
| qBittorrent initial identity | The selected source stores PBKDF2-SHA512 credentials with 100,000 iterations, a 16-byte salt and 64-byte output. A future initial-config renderer can seed its own generated password without reading a temporary password from logs; this requires an actual container fixture before support. After login, the app API can set download paths/categories and other fixed preferences. [Password implementation](https://github.com/qbittorrent/qBittorrent/blob/release-5.2.3/src/base/utils/password.cpp), [preferences API](https://github.com/qbittorrent/qBittorrent/blob/release-5.2.3/src/webui/api/appcontroller.cpp). |
| Prowlarr → Sonarr/Radarr | Stable `v2.5.2.5491` has `/api/v1/applications`; each application needs its private Arr URL/API key and Prowlarr's URL as seen by Arr. Application records require controlled idempotent reconciliation before indexer sync. [Application controller](https://github.com/Prowlarr/Prowlarr/blob/v2.5.2.5491/src/Prowlarr.Api.V1/Applications/ApplicationController.cs), [Sonarr settings](https://github.com/Prowlarr/Prowlarr/blob/v2.5.2.5491/src/NzbDrone.Core/Applications/Sonarr/SonarrSettings.cs). |

The six-entry catalog does not yet contain Prowlarr. A complete indexer wiring
path requires its own verified image/license/profile plus bootstrap adapter,
and user-selected external indexers/providers where accounts are necessary.
The existing six records must not be presented as a complete ready-to-use
download pipeline. Dependency notices, modified-file notices and any applicable
source obligations remain separate release work when binaries are redistributed.
MA's own [Apache 2 license](https://github.com/music-assistant/server/blob/2.10.2/LICENSE)
permits redistribution subject to retaining the license and applicable notices,
and identifying modifications; it does not grant trademark rights or replace
the licenses of bundled FFmpeg/native/provider components. Keep upstream brand
attribution in Larenor's legal/source surface and inventory the actual shipped
image's third-party obligations before redistributing an integrated image.

## Fit with the existing Server

Keep the current FastAPI process and SQLite database. Extend
[`CoreServices`](../core.py), [`runtime.py`](../runtime.py), and the existing
admin dependency when implementation starts. The current API container runs as
UID/GID 10001 with one Uvicorn worker and needs no Docker socket; preserve that
contract. No Redis, Celery, dynamic Python imports, marketplace downloader, or
second public management API is needed for S06.

[`services/`](../services/) already owns connections to existing services,
encrypted credentials, configuration revisions, and read-only verification.
Plugin installation must have separate records and authority. Forgetting an S05
connection never removes a container, and completing an installation never
silently adopts an existing CasaOS container or transfers its credentials.

Worker verification may start with one reviewed component through disposable
fixtures, then reuse that path for the remaining components. The user-facing
operation remains one stack installation. Each component becomes usable only after its exact
image, architecture, configuration, and health behavior pass the same checks.
Catalog entries lacking this evidence can be visible with a static unavailable
reason. Their presence must not be presented as installation support.

## Catalog and immutable plans

Ship a small, validated JSON catalog with the Server and worker packages. The
worker loads its own operator-owned copy and rejects a different catalog
digest. A Client cannot supply another catalog URL, image, command, Compose
document, Python module, host path, or Docker option. Updating the catalog is
initially a reviewed package update, not a background remote fetch.

The exact delivered models are in `models.py`. The following table also includes
future worker/job metadata and must not be treated as an implemented wire schema:

| Field | Meaning |
| --- | --- |
| `serviceId`, `distributionId`, `version` | Stable service family, selected distribution, human-readable release |
| `upstreamRepository`, `sourceRepository`, `sourceRevision`, `license` | Source and licensing provenance for the selected distribution |
| `manifestVersion`, `configSchemaVersion`, `dataSchemaVersion`, `apiCompatibility` | Explicit validation and compatibility boundaries |
| `images` | Exact repository plus SHA-256 digest for each supported `linux/amd64` or `linux/arm64` platform; no floating tags |
| `capabilities` | Initially `install`; future upgrade/removal support requires its own reviewed contract |
| `configSchema` | Packaged allowlist of typed, bounded settings and defaults; unknown fields rejected |
| `ports`, `storage`, `network`, `resources`, `health` | Required ports, storage roles/minimum free bytes, network profile, resource limits, and packaged health-check identifier |

Public responses include a `catalogDigest` and per-entry `manifestDigest` over
canonical JSON. Digests are lowercase SHA-256; identifiers are bounded ASCII;
integers are bounded and booleans are strict. Schema definitions have no remote
references. The JSON canonicalization rules are part of manifest version 1:
UTF-8, sorted keys, compact separators, no floats, and rejection of duplicate
keys. Do not invent current upstream versions or image digests while preparing
the framework; pin and verify them when adding each actual entry.

An `InstallPlan` selects one manifest, architecture, and image digest. It includes
the normalized settings, generated installation/resource identities, explicit
port bindings, storage-root IDs, requested capabilities, disk requirements,
health-check profile, and ordered steps. Worker-owned configuration resolves
storage-root IDs to paths. The Client never supplies an arbitrary absolute path.
S06 preview settings contain no provider credentials. The provisioning layer
must generate and retain internal credentials privately, bootstrap service
accounts, and connect Seerr/Jellyfin/Arr/download components without asking the
user to copy URLs or API keys. External provider accounts still require explicit
user settings when the provider demands them. S05 is optional for existing
external services, not a required step in a new Larenor installation.

Plans expire after 10 minutes and contain `id`, `revision`, `planHash`,
`createdAt`, `expiresAt`, `workerId`, `workerPolicyDigest`, `catalogDigest`, and
the actor identity/revision that requested the preview. A hash covers the full
immutable plan, including defaults and privilege requests. Public previews show
the selected source/image/version, effects, ports, storage, network access,
capacity observations, and static conflict/warning codes.

Preview asks the worker only for read-only inspection. It does not pull images,
create directories, reserve ports, start containers, or write external settings.
Port/free-space observations are advisory: the worker checks again before the
first mutation, and an actual Docker bind failure is an explicit conflict. Any
plan, catalog, worker policy, or selected-input change requires a fresh preview
and confirmation; the worker cannot silently choose a different port or image.

## Proposed Client API

All routes have the `/api/v1` prefix and require a current Server administrator
whose initial password has been changed. Use the existing strict models,
`ObjectId`, static error envelope, body limit, and transaction-time admin check.
IDs use the existing 32-character lowercase hex format. Times use UTC ISO 8601;
revisions use the existing bounded positive integer convention.

| Route | Request and result |
| --- | --- |
| `GET /admin/plugins/catalog` | `{catalogDigest, entries, worker}`; `worker` reports availability/platform, not arbitrary host inventory |
| `POST /admin/plugins/previews` | `{serviceId, distributionId, manifestDigest, settings}` → `201 {preview}` |
| `POST /admin/plugins/jobs` | `{previewId, expectedRevision, planHash, requestId}` → `202 {job}`; explicit installation confirmation |
| `GET /admin/plugins/jobs?before=…&limit=…` | `{jobs, nextCursor}`; stable descending pagination, default 25 and maximum 100 |
| `GET /admin/plugins/jobs/{id}` | `{job}`; admin-only status after reconnect or uncertain submission |
| `GET /admin/plugins/jobs/{id}/events?after=…&limit=…` | `{events, nextCursor}`; monotonically numbered, bounded, redacted phase/outcome events |
| `POST /admin/plugins/jobs/{id}/cancel` | `{expectedRevision}` → `{job}`; stop undispatched work and request a stop at the next safe boundary |

`requestId` is a Client-generated 32-hex idempotency key scoped to the submitting
user. Persist a unique `(actorId, requestId)` index and the confirmation payload
digest atomically with the job. The same payload returns the same job, including
after a lost response; a different payload returns 409. The same preview cannot
create a second job under a new key. Client retries must preserve `requestId`.

A public job contains `id`, `revision`, `installationId`, `serviceId`,
`distributionId`, `planHash`, `state`, `phase`, `cancelRequested`, timestamps,
and a typed `outcome` with a static code and optional installation summary.
States are `queued`, `running`, `succeeded`, `failed`, `cancelled`, and
`needs_attention`. Phase codes describe observed work; a percentage is omitted
unless an adapter provides a meaningful bounded measurement. Engine output,
container environment, credential values, and raw exception text are never job
events or API responses.

Cancellation is not rollback. A running step may finish before cancellation is
observed, and created data is preserved. A successful job means its catalog
runtime health criterion passed; it does not mean provider authentication,
media playback, casting, or physical-device operation succeeded. Return the
suggested S05 kind/base URL for a separate explicit connection action.

## Persistence, dispatch, and authorization

Add `plugins_schema=1` under the existing initialization lock and database
transaction, following [`services/schema.py`](../services/schema.py). Reject
unknown versions or partial tables. Proposed tables are `plugin_previews`,
`plugin_jobs`, `plugin_job_events`, and `plugin_installations`; migrations must
not reset accounts, the vault, or S05 records.

Keep indexed IDs, state, revision, actor/request identities, timestamps, and
static event codes in normal columns. Encrypt settings, complete plans, worker
receipts, and installation configuration using the existing private vault key
with a distinct `larenor:plugins:schema=1:record-type:id:revision` AAD. AAD must
bind the actual type/ID/revision, and each write uses a fresh nonce. Do not share
that key or the main database with the worker. Corrupt records fail closed;
startup does not manufacture replacements. Each terminal job's compact
idempotency record remains durable even when its verbose events are pruned.

Start with one active installation globally and at most 16 queued jobs, 128
unexpired previews, 10,000 jobs/idempotency records, and 10,000 retained job
events. Reject new work at capacity;
expire unused previews and prune terminal events deterministically. Keep
installation ownership records and idempotency tombstones until an explicit
future retention policy permits removal. Page through jobs rather than loading
unbounded history. Existing job status remains readable when the worker is
offline; preview/confirmation returns a static unavailable error.

Use one lifespan-managed dispatcher in the current single-process Server. It
claims and advances persisted work using `BEGIN IMMEDIATE`, revision checks,
and a process lock; FastAPI response background tasks are not the durable queue.
Never hold a database transaction open during IPC, image pulling, or health
checks. Claim a step before sending it; persist its receipt before advancing.
On startup reconcile unfinished steps before dispatching new ones.

Confirmation rechecks the live principal and preview ownership inside the
transaction. Store the actor's user revision and session-family ID as the durable
authorization scope, not an access/refresh token. Before dispatching each new
mutating step, check that this user is still enabled, is still an administrator,
has the recorded user revision, has completed password change, and the session
family is neither revoked nor expired. Normal access-token refresh must not
cancel an approved job. Demotion, password reset, logout, family revocation,
cancellation, or preview expiry before job acceptance prevents new work.

An accepted worker step is bounded but cannot be retroactively undone when
authority changes. Its receipt can still be recorded by the internal dispatcher;
later mutation steps stop. If resources were already created, report
`needs_attention` with their managed identities rather than claiming a clean
cancellation. Administrator recovery requires a new preview/approval if it would
perform a new mutation. Read-only reconciliation can run without reviving the
original authorization.

## Worker boundary and interfaces

Package a separate Linux-only `larenor-plugin-worker` process, installed manually
by the operator. It owns the Docker connection and a private durable journal.
The API can reach only its narrow Unix-domain socket, mounted into the API
container separately from the Docker socket. Socket/parent ownership and modes,
Linux peer UID checks, and an explicitly configured allowed API UID establish
the local caller boundary. Reject unexpected peers and symlinked socket/state
paths. There is no TCP listener or shared end-user bearer token in S06.

The worker is trusted host-level code: access to the Docker daemon is not a
sandbox against a compromised worker. Its own catalog, policy, and executable
must be operator-owned and unavailable for API writes. The worker independently
validates the catalog/plan digest, requested fields, expiry, identities, and
allowed step order. Peer authentication alone does not authorize arbitrary
Docker operations.

Proposed internal interfaces; these are names for later code, not exports:

```python
Catalog.get(service_id, distribution_id, manifest_digest) -> CatalogEntry
PluginManagement.preview(actor, request) -> PreviewResponse
PluginManagement.confirm(actor, request) -> JobResponse
PluginManagement.jobs(actor, cursor, limit) -> JobsResponse
PluginManagement.cancel(actor, job_id, expected_revision) -> JobResponse
JobDispatcher.tick() -> None

WorkerClient.inspect(manifest_digest, settings) -> HostObservation
WorkerClient.apply_step(command: StepCommand) -> StepReceipt
WorkerClient.observe(job_id, step_id) -> StepReceipt
```

`StepCommand` carries the immutable plan, `jobId`, `installationId`, `stepId`,
an allowed step enum, a one-use dispatch ID, and a short start deadline. It
contains no shell/Compose payload. A command already durably accepted returns
the same receipt even if the start deadline has passed; an unseen expired
command is rejected. Changed content under an existing identity is a conflict.
Preview expiry governs accepting a new job. Once confirmation is durably
accepted before that expiry, its plan remains immutable for that job's bounded
lifetime; later steps use their own short start deadlines. An expired preview
must not invalidate an already completed step or authorize a second job.
The worker serializes operations with a process lock and records its intent
before each Engine mutation. Small versioned, length-prefixed JSON messages
over the Unix socket are sufficient: cap messages at 64 KiB, fail unknown
fields/versions, and bound each IPC exchange. Long operations return a receipt
to poll, never an open-ended HTTP request from the Client.

Start with fixed steps `preflight`, `pull_image`, `create_resources`,
`start_container`, and `check_health`. Preflight/health are read-only.
`create_resources` is a journaled sequence of individually identified network,
volume/directory, and container operations, not a purported atomic Docker
transaction. Use a narrow Engine adapter with explicit typed operations; do not
invoke a shell, pass user input as CLI flags, or enable arbitrary Engine paths.
Pull only the selected digest and verify the resulting platform/image identity.
Initial bounds: one active operation, 10 minutes per pull, 2 minutes for health,
and 30 minutes for a job. Timeouts after a mutation create uncertainty to inspect,
not permission to blindly replay it.

Resource names and labels include an operator-established Server instance ID,
installation ID, manifest/plan digest, and worker journal identity. A matching
name alone proves no ownership. A resource with conflicting labels or an
unrecorded external origin is a conflict, including existing CasaOS applications.
Before reusing a resource after restart, compare its full managed specification
and journal entry. Missing or corrupt journal state requires attention; never
infer ownership by scanning names and recreate a clean journal.

Worker-owned storage roots use generated per-installation subdirectories and
explicit media mount roles. Validate real ownership and resolved boundaries;
reject symlinks, path traversal, and mount escape. Existing media roots, when
explicitly configured by the operator and selected in the preview, are mounted
read-only by default. API secrets, Docker socket, host root, and worker state
can never be mount targets. No `privileged`, arbitrary devices, host PID/IPC,
capability additions, or unreviewed network profile is accepted. A service such
as Music Assistant may need a reviewed discovery/network exception; expose it
in that entry's preview and keep installation unavailable until the policy and
fixture tests support it. Do not silently weaken the default for all entries.

S06 exposes no removal, upgrade, automatic cleanup, or arbitrary ownership-adopt
operation. On failure, preserve created storage and report the exact managed
resources. A later reviewed recovery/removal plan can stop or remove only those
resources; existing media and provider data are never an implicit rollback.

## Recovery and acceptance before implementation is complete

| Interruption or race | Required behavior |
| --- | --- |
| Confirmation response lost | Retry the same request ID; return the original job |
| API dies before dispatch | Persisted queued job is re-authorized before dispatch |
| Worker accepts a command but reply is lost | Observe the same job/step ID; do not submit a fresh installation |
| Worker dies after create/start but before receipt | Reconcile its recorded intent against exact managed resource identity/specification |
| Worker unavailable or outcome cannot be proven | Preserve status/data and use `needs_attention`; no blind retry or destructive rollback |
| Catalog/policy/image or inputs change | Old plan cannot be confirmed/executed; require a new preview |
| Port, disk, or ownership changes after preview | Fail explicitly at recheck; never relocate or adopt resources automatically |
| Actor loses authority or cancels during a step | Record the actual step result, stop further mutation steps, preserve resources |

Implement meaningful tests before claiming S06 delivery: all admin/initial
password/member and stale-principal gates; request-ID and preview races;
plan/digest/expiry validation; separate encryption AAD and restart/tamper;
worker peer/protocol/path/catalog limits; authority loss between steps; every
intent/Engine-result/receipt crash boundary; and no secret/raw Engine output in
API errors, event feeds, logs, or OpenAPI examples. Tests must distinguish
runtime health from service authentication and retain existing S05 semantics.

Use an in-memory fake Engine for deterministic failure injection, Unix sockets
and temporary SQLite state for worker integration, then a disposable Linux
Docker fixture for real pull/create/start/restart reconciliation. A fake Engine
pass does not establish a working Docker install. Test both supported Linux
architectures and the actual packaged worker before enabling an entry. No live
Home Assistant, media library, CasaOS installation, or physical receiver is
needed or authorized for this preparation.

Suggested implementation order: strict catalog/plan models and persistence;
preview/confirmation/status API with a fake worker; Unix worker journal and
fixed Engine operations; restart/uncertain-outcome integration tests; Client
catalog/preview/job screens; then reviewed per-service entries and disposable
Linux acceptance. Keep S07 provider setup/adoption and S08 remote device actions
outside the initial S06 contract.
