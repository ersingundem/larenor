# Larenor Server container

`server/Dockerfile` packages the Python Larenor Server: accounts, administration,
encrypted configuration storage, and verified Client releases. The normal
`larenor_server.cli` entry point assembles all four APIs. This image does not
include Music Assistant or manage the host Docker daemon.

The container build is defined here; a runnable release must first pass the
hosted image workflow and receive a published image digest. Docker was not
available during the initial local implementation, so local policy checks are
not evidence that either architecture has built or started successfully.

## Build from a reviewed source commit

Run these commands from a clean, committed repository checkout with Docker
BuildKit available. The revision must identify the exact source being built.

```sh
test -z "$(git status --porcelain)"
revision="$(git rev-parse HEAD)"
docker build --file server/Dockerfile \
  --build-arg "LARENOR_SOURCE_REVISION=$revision" \
  --build-arg LARENOR_REPOSITORY_URL=https://github.com/ersingundem/larenor \
  --tag "larenor-server:sha-$revision" .
```

For a fork or modified distribution, set `LARENOR_REPOSITORY_URL` to the public
repository containing its corresponding source. The image embeds the full
40-character revision and commit-specific source/license links, exposed by
`GET /api/v1/source`. An empty or malformed revision fails the build.

The build context is the repository root. Docker automatically applies
`server/Dockerfile.dockerignore`, whose allowlist includes only the Server
package, dependency manifests, Dockerfile and required license material.
Client code, signing keys, Git history, tests, local environments, private
configuration, databases and runtime credentials are excluded. The APK fixture
used by CI is mounted into the smoke-test container; it is not shipped.

## Runtime contract

| Item | Contract |
| --- | --- |
| Platforms | Native `linux/amd64` and `linux/arm64` builds |
| Process | UID/GID `10001:10001`; one Uvicorn worker |
| API | Port `8098`; health at `/api/v1/health` |
| Root filesystem | Compatible with read-only execution |
| Temporary files | Writable `/tmp`; CI uses a 64 MiB tmpfs with `nosuid,nodev,noexec` |
| Data mount | `/data`, owned by `10001:10001`, mode `0700` |
| Secrets mount | Separate `/secrets`, owned by `10001:10001`, mode `0700` |
| Vault key | `/secrets/vault.key`, mode `0600`; retained across restarts |
| Publisher credential | `/secrets/publisher.token`, mode `0600`; separate from the account database |
| Initial administrator | Random credentials in `/data/bootstrap-admin.txt`, mode `0600`; password change required |
| Initialization | `--initialize-only` initializes private state and exits |
| Privileges | No extra capabilities, privileged mode, host networking or Docker socket required |

Provide the two private writable mounts before starting with a read-only root
filesystem. Startup validates their ownership and modes; it does not repair
permissive existing paths or recreate a missing vault key for an existing
database. Back up the database and its separate key together while preserving
their separation and file permissions. Startup prints credential file paths,
not credential values. No account password, publisher token or vault key is
baked into the image.

The default environment sets `LARENOR_DATA_DIR`, `LARENOR_KEY_FILE`,
`LARENOR_PUBLISHER_TOKEN_FILE`, `LARENOR_JAVA`, `LARENOR_APKSIG_JAR` and
`LARENOR_APKSIG_CLASSES` to the packaged locations. Dependencies and verifier
classes are prepared during the build; startup never installs packages.
Operator installation on Linux or CasaOS is a separate, explicit manual step.

## APK verifier and notices

The Java 17 stage compiles `org.larenor.updates.VerifyApk` against official
Google Maven `apksig:9.1.0`, verified with SHA-256
`562cd0a88890960d2ece48e116c61f12872222f1dcc306890799382bc019b201`.
The runtime checks the JAR's hash again before verification. The verifier reads
the APK signature and binary manifest; it never installs or executes the APK.

A target-platform `jlink` runtime includes the cryptographic provider needed
for verification. Its C++/GCC support libraries live in a private directory;
the fixed `/usr/bin/java` launcher supplies that directory even though the
Server clears ambient environment variables before spawning Java. The native
CI smoke test must validate this Jammy-to-Bookworm runtime combination on both
architectures before publication.

`LICENSE`, `NOTICE`, `THIRD_PARTY_NOTICES.md` and the APKsig Apache 2.0 license
are retained in `/usr/share/doc/larenor-server/`. Java's module notices remain
under `/opt/larenor/java/legal/`, native support-library notices under
`/opt/larenor/java-native/legal/`, and Python dependency notices stay with their
installed package metadata. The Larenor license does not replace those licenses.

## Publication gates

`.github/workflows/server-build.yml` accepts trusted upstream `main` pushes
and manual runs on that same branch. Manual runs default to build and test
only; their `publish` input must be selected to publish. Pull requests and
forks cannot enter these publication jobs.

1. The reusable `server-test.yml` workflow must pass, including authentication,
   encrypted storage, administration, release APIs and real APK verification.
2. Each native architecture runner builds and loads its image locally. Before
   publication it runs initialization without networking, then a container with
   a read-only root, dropped capabilities and `no-new-privileges`. It checks
   public source metadata, protected APIs, private file ownership/modes,
   credential persistence across restart, and the real signed AOSP fixture.
3. Only the tested local image is pushed as
   `ghcr.io/ersingundem/larenor-server:sha-<40-character-commit>-<architecture>`.
   Existing tags are resolved to immutable digests and re-tested instead of
   overwritten. Authentication, network or malformed registry responses fail
   closed; only HTTP 404 means the tag is unused.
4. After both architectures pass, the workflow creates the immutable
   `:sha-<40-character-commit>` index. It promotes that index to `:stable` only
   after rechecking current upstream `main`. A single concurrency group cancels
   superseded runs, and main is checked before architecture publication too.

A failed second architecture may leave a tested per-architecture commit tag;
it cannot advance the final commit index or `stable`. Installations should pin
the verified multiarchitecture digest printed in the successful workflow
summary. The moving `stable` tag is a discovery convenience, not an immutable
installation reference.

No large image archives or Docker build-record artifacts are uploaded to
GitHub Actions storage. The reusable Server tests retain their small JUnit
evidence separately. Image build/push actions and checkout use official
repositories pinned to full commits. The workflow uses JSON, valid YAML, so
its permission and dependency graph can be tested without a YAML dependency.

## Verification and pin provenance

Local check:

```sh
python3 tool/tests/server_container_policy_test.py
```

These tests parse the workflow graph, check container boundaries, parse embedded
shell/Python without execution, and exercise registry failure handling with
synthetic responses. They do not build an image, start a container, access
GHCR or trigger CI.

The official registries were read on 2026-09-05. Each index includes AMD64 and
ARM64, and its registry digest matched the hash of the returned manifest bytes:

| Base image | OCI index digest |
| --- | --- |
| `python:3.12.14-slim-bookworm` | `sha256:782412e85d0f0984994c290652577d4018aff08145c85b262bb63dc0c7522254` |
| `ghcr.io/astral-sh/uv:0.12.10` | `sha256:2bb3ebca0a796a155094a27773d290c4b074572e6107f171d88d086682fd2500` |
| `eclipse-temurin:17-jdk-jammy` | `sha256:400014962ad7224461f945bb1cc3d7d5a1927ce15b8245b72d9cedcda554cd2a` |

Primary references: [Python registry manifest](https://registry-1.docker.io/v2/library/python/manifests/3.12.14-slim-bookworm),
[uv registry manifest](https://ghcr.io/v2/astral-sh/uv/manifests/0.12.10),
[Temurin registry manifest](https://registry-1.docker.io/v2/library/eclipse-temurin/manifests/17-jdk-jammy),
[exact Temurin build source](https://github.com/adoptium/containers/blob/33e90a8e65658c51e78419e09f12fb86de0fa3e3/17/jdk/ubuntu/jammy/Dockerfile),
[uv container guidance](https://docs.astral.sh/uv/guides/integration/docker/),
and [Dockerfile reference](https://docs.docker.com/reference/dockerfile/).

Docker action pins resolve to the official stable releases
[setup-buildx v4.3.0](https://github.com/docker/setup-buildx-action/releases/tag/v4.3.0),
[login v4.6.0](https://github.com/docker/login-action/releases/tag/v4.6.0) and
[build-push v7.3.0](https://github.com/docker/build-push-action/releases/tag/v7.3.0).

## Security scan evidence without artifact storage

At commit `5331f22f2c3d1eee9a0959fa8409346e3bfaa1cb`,
[Security run 33955738706](https://github.com/ersingundem/larenor/actions/runs/33955738706)
reported no leaks and no dependency issues, then failed when uploading artifacts
because GitHub Actions storage was full. This is evidence about that run's scan
scope: one commit and 202 packages from `pubspec.lock`.

The [pinned Gitleaks action](https://github.com/gitleaks/gitleaks-action/blob/ff98106e4c7b2bc287b24eaf42907196329070c7/src/index.js)
supports disabling artifact uploads while retaining redacted summaries and
nonzero scan exits. The
[pinned OSV reusable workflow](https://github.com/google/osv-scanner-action/blob/8deb546fdb875b9996d27d4950be7312dac076a1/.github/workflows/osv-scanner-reusable.yml)
always uploads an artifact, even with `upload-sarif: false`. Its
[scanner-action wrapper](https://github.com/google/osv-scanner/blob/a258868211a57052da6bd323f758b8388dee02bb/exit_code_redirect.sh)
also converts a no-packages exit into success.

Security CI therefore invokes the official OSV CLI container directly, with
both `pubspec.lock` and `server/uv.lock` required. Findings and errors remain in
the job log; its summary records the scan outcome. Every nonzero CLI or Docker
exit remains blocking, following the documented
[OSV return codes](https://google.github.io/osv-scanner/output/#return-codes).
No scanner result depends on an artifact upload.

On 2026-09-05, the
[official OSV v2.5.0 registry index](https://ghcr.io/v2/google/osv-scanner/manifests/v2.5.0)
contained AMD64 and ARM64. Its digest matched the returned bytes:
`sha256:5b8b38e45bb2c5c4976f0f1f07860551ea6e1f235f642cf215f74d266fec2c1b`.
The AMD64 configuration identifies source revision
`a258868211a57052da6bd323f758b8388dee02bb` and the direct `/osv-scanner`
entrypoint. Offline tests exercise successful scans, six nonzero exits, and
both missing-lockfile cases using a synthetic Docker executable; they do not
claim that a real container ran locally.
