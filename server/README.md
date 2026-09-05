# Larenor Server

Larenor Server is the API backend for Larenor Client, the tablet-first Android
app. The same Android app supports Samsung DeX and resizable windows.
It has no separate web admin application: administrative features
belong in the Client and are authorized again by the Server.

Accounts, the encrypted vault, user/session administration, encrypted service
connections and signed Client release APIs have corresponding Client screens.
The Server container has passed native amd64/arm64 CI checks. Internal component
catalog, requirements previews, durable read-only inspection jobs and unified
encrypted media preparation history are
implemented, with an optional internal Linux worker and Client administration.
Installation and automatic media wiring remain in development. See the
[implementation plan](../docs/server-client-architecture-2026-09-05.md) for the
current boundary; a planned operation is not an available endpoint.

## Local development and tests

Python 3.12–3.14 is supported by the dependency declaration. CI uses Python
3.12.14 and uv 0.12.10, installing exact versions/hashes from `uv.lock`.

```sh
cd server
uv sync --locked --python 3.12.14
```

The full suite also requires a Java 17+ JDK and `LARENOR_TEST_APKSIG_JAR`
pointing to Google's `com.android.tools.build:apksig:9.1.0` artifact. Its required
SHA-256 is `562cd0a88890960d2ece48e116c61f12872222f1dcc306890799382bc019b201`.
CI downloads that exact artifact and verifies its digest before testing. The
tests compile the bundled Java verifier and check a real signed AOSP APK plus
tampered variants; missing prerequisites fail instead of skipping crypto tests.
With those prerequisites prepared, run
`uv run --locked --no-sync python -m pytest tests`.

Use separate private directories for runtime data and the encryption key. Set
`LARENOR_DATA_DIR` to the data directory and `LARENOR_KEY_FILE` to a key file
outside it. Neither location belongs in Git or a public artifact. Then run:

```sh
uv run --locked --no-sync larenor-server --host 127.0.0.1 --port 8098
```

The initial `admin` password is randomly generated once and written to a local
file with mode 0600. Startup prints its path, not the password. Change the
password in Larenor Client after the first login. `--initialize-only` prepares
the data/key/bootstrap files and a separate release publishing credential
without listening on a socket. Both credential paths are printed; their
contents are never logged. The publishing credential defaults to
`publisher.token` alongside the vault key, outside the database directory.
`LARENOR_PUBLISHER_TOKEN_FILE` can select another private file. Existing valid
credentials are preserved on restart.

Production CasaOS/Linux Docker installation remains a final manual setup step.
Use an authenticated private network and HTTPS at the deployment boundary for
credential transport. SQLite is configured with WAL, transactions, a busy
timeout and full synchronization. The vault encryption key is separate from
the database; preserve both in a consistent private backup. Missing keys on an
existing installation fail closed instead of creating an unreadable new vault.

## API and OpenAPI

All application routes use `/api/v1`. The account core provides health,
login/refresh/logout, current user, password change and revision-controlled
vault reads/writes. Roles are `admin` and `member`; the first password change is
mandatory before protected application APIs can be used. Refresh tokens rotate
once and are stored as hashes; password changes revoke prior sessions.

`GET /api/v1/context` returns `{schemaVersion: 1, coreId, homeId}` to a ready
authenticated user. These opaque IDs survive restart and belong to the one
current Core/home; this is not multi-home administration. Main database schema
3 adds the identity atomically after validating the existing vault key. Missing
or corrupt current identity fails startup rather than generating replacements;
legacy schema 1/2 upgrades preserve accounts and vaults. See the
[context implementation and migration tests](../docs/core-context-implementation-2026-09-05.md).

`GET /api/v1/openapi.json` returns the actual typed OpenAPI contract to an
authenticated administrator who has changed the initial password. Supply an
access token in the `Authorization: Bearer …` header, never in a URL. Import
this schema into a local Swagger-compatible API tool. Public `/docs`, `/redoc`
and `/openapi.json` pages are disabled. Normal users cannot gain administration
rights by changing a Client screen or local Settings PIN.

Administrators can list/create users, update role/disabled state using an
expected revision, reset another user's temporary password, page through
sessions/audit events, and revoke sessions. The last active administrator cannot
be removed. Role/password changes revoke the affected sessions.

Vault documents wrap the existing Client `BackupSnapshot` v2. Only known groups
and mandatory privacy metadata are accepted. AES-GCM encrypts stored documents;
the Server can decrypt them for the authenticated owner. This is encryption at
rest, not a zero-knowledge or end-to-end encryption claim. Revision conflicts
return 409 and require a new read/preview before replacement.

## Service connections and internal components

Current administrators manage encrypted connection records and bounded service
identity checks through `/api/v1/admin/services`. The
[service connection guide](../docs/server-service-connections.md) documents the
17 supported record types, revision checks and verification states. Storing or
checking a connection does not install that service or transfer all of its
operations to the Server.

The component API provides these administrator-only routes:

| Route | Result |
| --- | --- |
| `GET /api/v1/admin/plugins/catalog` | Six pinned component manifests; installation capability remains disabled |
| `POST /api/v1/admin/plugins/previews` | Deterministic requirements preview for validated catalog settings and architecture |
| `GET /api/v1/admin/plugins/previews/{id}` | Unexpired preview belonging to the same user and session family |
| `GET /api/v1/admin/plugins/jobs/capabilities` | `preflightConfigured` and `installAvailable: false`; configuration does not prove worker connectivity |
| `POST /api/v1/admin/plugins/jobs` | `202 {job}` for `operation: "preflight"`, exact preview revision/hash and a 32-hex `requestId` |
| `GET /api/v1/admin/plugins/jobs` | Current administrators' shared job history, paginated by `before` / `nextBefore` |
| `GET /api/v1/admin/plugins/jobs/{id}` | Durable status and bounded observation results, including after preview expiry |
| `GET /api/v1/admin/plugins/jobs/{id}/events` | Static activity codes, paginated by `after` / `nextAfter` |
| `POST /api/v1/admin/plugins/jobs/{id}/cancel` | Revision-checked cancellation of queued work or a cancellation request for running inspection |

Preview generation performs no host inspection, Docker action or remote service
request. Plans are encrypted in the database, bound to the current catalog and
administrator revision, and expire after ten minutes. Storage is capped at 128
previews. Refreshing an access token within the same session family preserves
access; another login or device cannot retrieve that preview.

In the Client, a signed-in administrator opens **Server components** through
Settings and its PIN gate, reviews a component's requirements, then chooses
**Check requirements** when the optional worker is configured. **Check history**
shows durable jobs, per-requirement results and activity, with explicit refresh
and cancellation. A lost submission can be recovered using the same request ID;
the Client does not automatically create a replacement job. Backgrounding,
leaving the protected route or changing account retires its active interactions.
Music Assistant remains a planned internal music engine, without a separate
user installation or URL/token setup flow.

A job state of `succeeded` means **inspection completed**. Individual checks may
still be `failed` or `unknown`. The current worker observes platform and approved
storage roots/capacity. An explicit version-2 operator policy can also check
Docker API/platform compatibility. Port availability and receiver networking
remain `unknown`. It never pulls an image, creates component storage, starts a service,
changes host configuration or enables installation. Every catalog plan remains
`installable: false`, and job capabilities always report `installAvailable: false`.

Jobs keep their encrypted plan/results after the preview expires. Dispatch checks
the original administrator revision and session family before inspection and
again before publishing results; normal access-token refresh is allowed. An API
restart may repeat interrupted read-only inspection after those checks. One job
runs at a time, at most 16 are queued, history is capped at 10,000 jobs, and only
the newest 10,000 static activity events are retained. No Redis or separate public
management API is involved.

## Unified media preparations

The administrator's **Server components → Media preparation** screen stores one
plan for qBittorrent, Sonarr, Radarr, Jellyfin, Seerr and Music Assistant. Common
settings select approved root IDs and architecture; no arbitrary host paths,
images or permissions are accepted. This does not install or start components.

`POST /api/v1/admin/media/preparations` returns `201 {preparation}`. The request
includes a 32-hex `requestId`, `templateId: "media"`, reviewed Core/home context,
catalog digest, platform and settings. Repeating the same user's identical
request returns the same record, including after cancellation. Changed input
or an active duplicate instance name returns a conflict.

`GET` on that collection supports `limit` 1–10 and `before`; `GET /{id}` reads
one record. `POST /{id}/cancel` takes `expectedRevision`; revision 1/prepared
becomes 2/cancelled without deleting data. History survives restart and creator
logout; current administrators can read/cancel it even after a catalog upgrade.
`catalogCurrent` distinguishes an older plan from current package pins.

Records are AES-GCM encrypted with bound metadata, capped at 256 total / 8
active, and available without configuring the optional requirements worker.
Stable component/operation/step IDs separate the six components. Requested
resource totals are not measured host capacity. `installAvailable` remains
false and bootstrap exposure unverified. See the
[implemented contract and remaining steps](../docs/media-preparations-implementation-2026-09-05.md).

## Aggregate media inspections

From a current media preparation, **Check requirements** creates an encrypted,
durable observation through `/api/v1/admin/media/inspections`. `POST` takes
`requestId`, `preparationId`, `expectedRevision` and `planHash`, returning
`201 {inspection}`. `GET` lists at most ten records per page; `GET /{id}` reads
one result and `POST /{id}/cancel` uses `expectedRevision`. `/capabilities`
reports `inspectionConfigured` and `installAvailable: false`.

The six components' disk budgets are aggregated per writable filesystem;
shared storage must accommodate the combined 49,152 MiB proposal. Worker-local
storage and Docker API compatibility remain separate from daemon mount,
network and process-root context observations. Missing context evidence leaves
those checks `unknown`; ports and receiver networking remain `unknown`.

Only an explicit version-3 worker policy with an operator-selected trusted
`docker.daemonExecutable` can enable Linux peer-context evidence. Version-1/2
policies keep their existing scope. The same socket's peer pidfd requires Linux
6.5 or later; unsupported kernels or unavailable process evidence do not prevent
ordinary API checks, but do not prove matching host context.

History survives restart and supports the same request ID after an uncertain
response. Original actor/session, preparation, catalog and Core/home authority
are rechecked before and after observations. The bounded store holds at most
256 inspections, 16 active, and one active inspection per preparation. No
container installation is enabled. See the [implemented contract, test evidence
and limits](../docs/media-inspections-implementation-2026-09-05.md).

## Optional internal requirements worker

The default Server has no configured preflight worker. History remains available;
creating a job returns `plugin_worker_unavailable`. The same Server package ships
`larenor-preflight-worker`, an internal operator/runtime entry point for Linux
AMD64/ARM64. It uses a private Unix socket and real Linux peer credentials, with
no TCP listener or shared Client token. Only the worker may receive an explicitly
configured Docker socket for its fixed read-only version check; the API does not
receive that socket. It is not another product
or an end-user application to configure separately.

The future unified installer must supply its private policy, approved root IDs
and process supervision. For the current operator interface, policy format,
`--check-config`, socket ownership and recovery, see the
[implemented worker contract](larenor_server/plugins/README.md#internal-worker-configuration-and-lifecycle).
The API selects its optional connection through `LARENOR_PLUGIN_WORKER_SOCKET`
(an absolute socket path) and `LARENOR_PLUGIN_WORKER_UID` (the actual worker UID,
default `0`). Invalid values fail startup with the static code
`invalid_worker_configuration`, without echoing environment values. The API
container's default entry point starts only the API, not this worker.

The product target remains [one integrated media/music installation](../docs/integrated-media-stack.md),
with users managing settings in Larenor Client and internal credentials and
connections managed by Larenor. Complete-stack provisioning, service bootstrap,
private control networking and actual media runtime deployment are still future
work. The current job API rejects installation operations.

## Client releases

The normal `larenor-server` entry point also registers `/client/releases`.
`GET /client/releases/latest` returns 204 until a release has been published.
Latest metadata and APK downloads require an authenticated user whose initial
password has been changed. Publishing uses the separate `lpub_…` credential,
never an administrator's access token.

Publishing reserves metadata with `PUT /client/releases/{versionCode}`, streams
the APK to the returned upload ID, and explicitly finalizes verification. A
published version is immutable. Storage is bounded, interrupted uploads are
reclaimed safely, and a new latest pointer is committed only after verification.
The typed JSON and binary-body contracts appear in the protected OpenAPI schema.
`tool/publish_client_release.py` at the repository root implements this protocol;
its `--help` documents the APK/metadata/server inputs and private token-file option.

The packaged verifier requires Java, the pinned apksig jar and compiled
`org.larenor.updates.VerifyApk` classes. Development paths can be configured with
`LARENOR_JAVA`, `LARENOR_APKSIG_JAR`, and `LARENOR_APKSIG_CLASSES`. Missing or
modified verifier files reject publication; they never bypass verification.
The public Client signing certificate is pinned by default. Forks must set
`LARENOR_CLIENT_SIGNER_SHA256` to their own reviewed certificate and preserve it
across Client upgrades. `LARENOR_RELEASE_DIR` defaults to `releases/` under data.

Private home-network delivery from CI and the final CasaOS installation still
require the agreed manual deployment step. No production publication or live
device update has been performed by these local tests.

The signed Android workflow contains an optional Server publishing step. At
manual setup, set repository variable `LARENOR_RELEASE_SERVER_URL` to the
reachable HTTPS base URL and repository secret `LARENOR_RELEASE_PUBLISH_TOKEN`
to the Server's dedicated publishing credential. Leaving the URL unset keeps
this step disabled. The job requires all Client/native/E2E/Server tests, verified
signing, a trusted main run and a fresh main-commit check before upload. It never
uses an administrator password, follows redirects, or automatically retries an
uncertain upload. HTTPS/VPN or a separately reviewed local delivery arrangement
is still needed for a Server reachable only on a private LAN.

## License and source

Original Larenor Server code is **AGPL-3.0-only**; see [LICENSE](../LICENSE),
[NOTICE](../NOTICE) and [third-party notices](../THIRD_PARTY_NOTICES.md).
The corresponding source and build scripts are in
[ersingundem/larenor](https://github.com/ersingundem/larenor). Distributors and
operators of modified versions must provide the source access required by the
license, pointing users to the exact version they run, including their changes.
External service images and future upstream forks retain their own licenses.

`GET /api/v1/source` is public and returns source/license links, package version
and an optional build commit; it exposes no configured services or credentials.
Container builds should set `LARENOR_SOURCE_URL`, `LARENOR_SOURCE_REVISION` and
`LARENOR_LICENSE_URL` to their exact source revision. Modified distributions
must point these at their own corresponding source, rather than an unchanged
upstream revision.
