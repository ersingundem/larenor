# Larenor Server

Larenor Server is the API backend for Larenor Client on Android tablets and
Samsung DeX. It has no separate web admin application: administrative features
belong in the Client and are authorized again by the Server.

Accounts, the encrypted vault, user/session administration and signed Client
release APIs are implemented. Client UI integration, container delivery and
managed plugins are being completed. See the
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
