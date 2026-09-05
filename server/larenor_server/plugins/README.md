# S06: internal components and requirements checks

The delivered slice, 5 September 2026, includes the immutable component catalog,
offline requirements previews, encrypted durable inspection jobs, Client
administration and an optional internal Linux requirements worker. The actual
contracts are in [`models.py`](models.py), [`api_models.py`](api_models.py),
[`job_models.py`](job_models.py) and [`preflight_models.py`](preflight_models.py).
All six component records remain `installable: false`. Completed inspections do
not establish that an image was started, installed on CasaOS or tested with a
physical player.

The product boundary is **one Larenor Server installation and account**, with
the media components provisioned and connected internally. Users manage media
settings through Larenor, without separately installing these applications or
copying their URLs/API keys. `managed_service` describes the five internally
managed media components; `internal_engine` identifies Music Assistant as the
Larenor music engine. Neither role means an independent user installation.
Per-component plans are internal building blocks for a later complete-stack
preview and provisioning job. Existing external S05 connections remain an
optional compatibility path. The job and worker interfaces documented below
are implemented for read-only inspection. Complete-stack installation,
bootstrap and interconnection are future work, described separately at the end.

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
The delivered inspector checks approved root purpose, ownership, free space and
symlink boundaries without creating directories. A future provisioner must also
validate resource ownership and conflicts before any mutation.

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

## Implemented Client and API flow

Administration stays in Larenor Client, behind its Settings PIN and a current
Server administrator account whose initial password has been changed. In
**Server components**, review a supported component's settings and platform,
then open **Check requirements** from its preview. The check screen shows whether
the internal worker is configured and asks for an explicit check. **Check
history** is also available without creating a preview. Music Assistant is
presented as Larenor's planned internal engine, with no standalone installation
or engine URL/token setup action.

The Client distinguishes **Inspection completed** from each requirement's
**Passed**, **Not met** or **Could not verify** result. It supports bounded
foreground polling, manual refresh, earlier history/activity pages and explicit
cancellation. After an uncertain submission, **Recover submission** reuses the
original request body and ID; it does not silently request another preview or
launch another job. Leaving the protected route, backgrounding, PIN changes or
account changes retire pending UI interactions. The Server independently checks
authorization for every API operation.

All routes below have the `/api/v1` prefix. The actual router and models are
[`api.py`](api.py), [`job_api.py`](job_api.py), [`api_models.py`](api_models.py)
and [`job_models.py`](job_models.py). The protected OpenAPI document is the
machine-readable contract; no separate web administration app is provided.

| Route | Implemented request / result |
| --- | --- |
| `GET /admin/plugins/catalog` | `{catalogDigest, entries, worker}`; six immutable manifests, installation disabled |
| `POST /admin/plugins/previews` | `{serviceId, distributionId, manifestDigest, platform, settings}` → `201 {preview}` |
| `GET /admin/plugins/previews/{id}` | `{preview}` for the original user/session family while unexpired |
| `GET /admin/plugins/jobs/capabilities` | `{preflightConfigured, installAvailable: false}`; configuration is not connectivity evidence |
| `POST /admin/plugins/jobs` | `{operation: "preflight", previewId, expectedRevision, planHash, requestId}` → `202 {job}` |
| `GET /admin/plugins/jobs?before=…&limit=…` | `{jobs, nextBefore}`; descending durable sequence, default 25 / maximum 100 |
| `GET /admin/plugins/jobs/{id}` | `{job}`; current administrator access to durable status |
| `GET /admin/plugins/jobs/{id}/events?after=…&limit=…` | `{events, nextAfter}`; ascending global event sequence, `after` defaults to 0, same page limits |
| `POST /admin/plugins/jobs/{id}/cancel` | `{expectedRevision}` → `{job}`; optimistic revision check |

The catalog's existing `worker` field describes disabled installation support.
Read `/jobs/capabilities` for the separately configured read-only worker. Neither
field enables installation. No operation in this component API accepts `install`, an arbitrary
command, image, host path, catalog URL, Docker option or provider credential.

IDs and request IDs are 32 lowercase hex characters; digests are 64 lowercase
hex characters. Times are canonical UTC ISO 8601 with milliseconds. Previews
have revision 1, expire after ten minutes and contain the full `InstallPlan`.
Preview calculation does not contact the worker or inspect the host. Storage is
capped at 128 previews. Opaque storage IDs are resolved only by worker policy.

A job exposes `id`, `revision`, `operation`, `previewId`, `requestId`, `serviceId`,
`distributionId`, `planHash`, `platform`, `state`, `phase`, `cancelRequested`,
`createdAt`, `updatedAt`, `result` and `errorCode`. Its full plan stays encrypted
internally instead of appearing in paginated history. Events expose only
`sequence`, `code`, `createdAt` and `jobRevision`; there are no engine logs,
absolute host paths, credentials or exception messages.

| Job state | Meaning |
| --- | --- |
| `queued` | Accepted durably, awaiting inspection |
| `running` | Checking requirements, possibly with cancellation requested |
| `succeeded` | Inspection completed; individual requirements may still fail or remain unknown |
| `failed` | Worker unavailable or returned an invalid result; no installation occurred |
| `cancelled` | Queued inspection cancelled, or a running inspection returned after cancellation was requested |
| `needs_attention` | Original authority or catalog no longer permits dispatch/result publication |

Phases are `queued`, `checking_requirements` and `complete`. A successful result
contains the catalog digest, plan hash, requested platform, observation time and
1–32 checks. Each check has a static `code`, `status` (`passed`, `failed` or
`unknown`) and nullable `rootId`, `availableMiB`, `requiredMiB`. The current worker
checks platform and approved storage roots/capacity. It deliberately reports
`docker_engine`, `port_availability` and `receiver_network` as `unknown`: it does
not contact Docker, bind ports or probe players. Disk requirements are proposed
catalog budgets, not measurements of upstream applications' actual minima.

## Persistence, dispatch and recovery

[`jobs.py`](jobs.py) uses the existing FastAPI/SQLite account store with separate
`plugin_jobs_schema=1` migration metadata in [`job_schema.py`](job_schema.py).
The preview migration remains `plugins_schema=1`. Unknown or partial schemas
fail startup without resetting accounts, previews or S05 connections.

Complete job requests, plans and results are AES-GCM encrypted with the private
vault key. Distinct AAD binds job identity, sequence, revision, original actor
and session family, request/preview IDs, state and timestamps. Static events
also have authenticated metadata. The worker receives neither this key nor the
API database. Corruption fails closed; startup validates retained rows one at a
time, with a count bound, instead of accumulating all encrypted history in RAM.

Creation rechecks current administrator authority and the exact unexpired
preview in a `BEGIN IMMEDIATE` transaction. A unique `(actor_id, request_id)`
record makes identical submissions return the same job, including after preview
expiry or a lost response. Different payloads under that ID, or a second job
for the same preview, return `plugin_job_conflict`. An existing idempotent reply
remains readable even if the worker is later unconfigured. Newly accepted work
requires a configured backend; actual connectivity is established during the job.

The immutable dispatch authority is the original user revision and session-family
ID, not an access token. The user must still be enabled, be an administrator,
have completed password change and retain that revision; the family must still
exist and be unrevoked/unexpired. These facts are checked before inspection and
again before publishing its result. Access-token refresh within that family is
allowed. Jobs have no foreign key to a preview or session family: preview expiry
and login's old-session retention cannot delete jobs or prevent another login.
Any current administrator may read history or request cancellation.

One inspection runs globally at a time, with at most 16 queued jobs. Accepted job
history/idempotency records have a hard cap of 10,000; new jobs are rejected at
capacity. The newest 10,000 static events are retained, so older event pages can
be empty even though their jobs remain readable. No job deletion/retention-reset
API is provided by this slice.

The API's lifespan dispatcher exists only when a backend was configured at
startup. It calls `JobManagement.tick()` outside response background tasks. A
local process lock spans an inspection; short SQLite transactions claim work
and persist transitions. No DB transaction stays open during worker IPC. On API
shutdown, the dispatcher stops scheduling and awaits the bounded request/result
write. On restart, queued or interrupted running jobs can repeat **read-only**
inspection only after fresh checks of the recorded authority and packaged plan.
Terminal jobs are not automatically retried. There is no mutation to reconcile
or roll back in this protocol.

Cancelling a queued job completes it immediately. Cancelling running work records
`cancelRequested`; when the call returns, its result is discarded and the job
becomes `cancelled`. Cancellation cannot forcibly interrupt a blocked filesystem
observation. No service, file or media data is removed. Worker failure becomes a
static failed job; authority loss becomes `needs_attention`. Retained history
remains available while the worker is stopped.

## Internal worker configuration and lifecycle

The same Server Python package exports
`larenor-preflight-worker = larenor_server.plugins.preflight_runtime:main`.
[`preflight_runtime.py`](preflight_runtime.py) is an internal operator/runtime
entry point, not a second user product or a separate media-app setup flow. A
future unified installer must supply its policy and supervision. The default
API/container entry point does not launch it. Current support requires Linux
`amd64` or `arm64`; production uses real `SO_PEERCRED` peer UIDs. Mac tests use
synthetic fixtures where required and do not establish a supported Mac daemon.

Policy is a regular, single-link file, mode **0600**, owned by the worker UID.
Its parents must be trusted and it cannot be a symlink. It is capped at 32 KiB;
unknown fields, duplicate keys, floats and invalid paths are rejected. Its exact
version-1 form is:

```json
{
  "version": 1,
  "roots": [
    {"id": "appdata", "path": "/srv/larenor/appdata", "purpose": "data"},
    {"id": "library", "path": "/srv/larenor/library", "purpose": "library"}
  ]
}
```

There must be 1–16 distinct root IDs. Purposes are `data`, `library`, `media` and
`music`, matched to the plan's corresponding setting. Paths are absolute,
canonical directories, with no traversal, control characters or symlink
resolution. Existing roots and their traversed directories must have trusted
ownership and not be group/world writable. The inspector walks directories by
file descriptor, rejects unsafe existing managed children and does not create
missing component subdirectories. It measures available space once per distinct
writable filesystem. It never exposes resolved host paths to the Client.

For an operator-prepared Linux runtime, these are the command forms. The example
assumes a worker running as UID 0 and an API running as UID 10001; actual UIDs,
group access and policy locations must match the chosen runtime:

```sh
larenor-preflight-worker --policy /etc/larenor/preflight.json \
  --socket /run/larenor/preflight/worker.sock \
  --api-uid 10001 --socket-gid 10001 --check-config

larenor-preflight-worker --policy /etc/larenor/preflight.json \
  --socket /run/larenor/preflight/worker.sock \
  --api-uid 10001 --socket-gid 10001
```

`--check-config` validates arguments, platform and the private policy only. It
opens no socket and does not inspect approved roots or establish their capacity.
It returns 0 without output on success. It is not a deployment or readiness test.

The socket parent must already exist and be worker-owned with trusted ancestors.
For different worker/API UIDs, `--socket-gid` is required; the runtime must give
the API appropriate group traversal/connect access without allowing it to write
the policy or runtime directory. The socket is mode 0660 with a selected group,
or 0600 for the same-UID configuration. Peer-UID checks still apply in either
case. Only length-prefixed JSON `status` and `inspect` operations are accepted;
packets are capped at 64 KiB and each exchange has a shared five-second deadline.
There is no TCP listener, shell command, Docker request or install operation.

On the API side, `LARENOR_PLUGIN_WORKER_SOCKET` selects the absolute socket path
visible to that process and `LARENOR_PLUGIN_WORKER_UID` selects the expected
worker UID (default 0). Leaving the socket unset keeps the dispatcher disabled.
Changing these values requires an API restart. Invalid values raise the static
startup code `invalid_worker_configuration`, without echoing environment text.
The internal worker CLI reports only `invalid_arguments` (exit 2),
`worker_platform_unsupported`, `worker_configuration_invalid` or
`worker_unavailable` (exit 1); successful checks and normal shutdown return 0.

SIGINT/SIGTERM stop the worker and restore its signal handlers. Its server closes
active socket reads, waits for inspection to unwind and removes only the inode
it recorded after binding. Even a permission-setting failure cleans only that
newly created inode. If inspection is still blocked at the shutdown deadline,
shutdown fails instead of releasing a live worker's lock for a replacement.
The API connection has its own bounded deadline and can fail before that host
observation returns.

An occupied endpoint is never adopted, replaced or blindly unlinked, including
a stale socket after a crash. Until managed runtime recovery is implemented,
the owning operator/runtime-directory manager must prove the old process has
exited and establish ownership before recovering that specific endpoint. Do not
delete arbitrary socket files or clear job state to force startup. A new worker
can serve later checks after safe recovery; failed terminal jobs need a new
explicit review/check, while interrupted API jobs retain their existing identity.

## Evidence and remaining provisioning work

Tests use synthetic accounts, temporary SQLite databases, bounded private Unix
sockets and disposable filesystem fixtures. They cover exact request identity,
concurrent queue admission, cancellation during inspection, access-token refresh,
revocation/demotion/session retention, interrupted-job recovery, encrypted
metadata tampering, history limits and startup memory bounds. Runtime tests cover
HTTP → SQLite → Unix inspection, API restart, peer credentials, malformed packets,
permission failures, socket ownership, signals and static errors. The relevant
files are [`tests/test_plugin_jobs.py`](../../tests/test_plugin_jobs.py),
[`test_plugin_job_runtime.py`](../../tests/test_plugin_job_runtime.py),
[`test_plugin_preflight_ipc.py`](../../tests/test_plugin_preflight_ipc.py),
[`test_host_preflight.py`](../../tests/test_host_preflight.py) and
[`test_plugin_preflight_runtime.py`](../../tests/test_plugin_preflight_runtime.py).
These results do not prove production CasaOS deployment, Docker installation,
HomePod operation or physical tablet acceptance.

[`worker.py`](worker.py) also contains an isolated, journaled foundation for
prepared-image container create/start operations. It is not exposed by the
preflight command, protocol or job API, and cannot promote disabled catalog plans
into installation support. Its synthetic Engine tests are separate evidence.

The next provisioning slice still needs a single-stack plan and policy binding,
private control networking, image/storage/network preparation, exact resource
ownership and restart reconciliation, generated credentials and bootstrap
adapters, automatic component interconnections and real disposable Linux image
acceptance on both architectures. It must preserve data on uncertain mutations,
refuse to adopt unrelated CasaOS resources, and retain separate licensing/source
obligations. Playback/discovery/provider acceptance requires its own evidence.
No removal, upgrade, automatic cleanup or device-changing operation is enabled.
The final user flow remains one Larenor installation and Client-managed settings.
