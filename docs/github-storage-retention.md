# GitHub storage retention

Larenor's cleanup utility is deliberately limited to `ersingundem/larenor` and the inventory of `ghcr.io/ersingundem/larenor-server`. It defaults to a dry run. It cannot delete releases, workflow runs, caches, other repositories, or container versions.

## Actions artifacts

Only the exact artifact name `app-debug-apk` is eligible. Its originating run must be completed and belong to this repository's `.github/workflows/android-build.yml`. Matching is exact: names such as `app-debug.apk`, signed APKs, security reports, test evidence, and unfamiliar outputs are preserved.

The newest three available debug APK artifacts are retained across the repository, ordered by creation time and then artifact ID. Expired artifacts are skipped. Older eligible artifacts can be removed without an additional age threshold. This is separate from the workflow's upload retention setting; keeping three does not extend GitHub's expiration date or recreate expired outputs.

Before deleting anything, the utility reads the complete paginated artifact snapshot and validates the candidate runs. Before **each** deletion it reads a fresh snapshot, recomputes retention with current UTC time, compares the exact artifact metadata, and checks its run again. It checks expiration once more immediately before issuing DELETE. Changed artifacts, restarted runs, or candidates that now fall within the newest three are skipped. Invalid or incomplete data blocks further deletion.

Each invocation permits at most 20 deletions. A same-host process lock prevents overlapping apply invocations. GitHub does not provide a transaction spanning inventory and deletion, so do not run this cleanup concurrently from multiple hosts or alongside another retention tool. The repeated checks reduce the race window; they cannot lock out independent GitHub users or automatic expiration.

Only a confirmed HTTP 204 increments `deletedIds` and `deletedBytes`. An uncertain response stops the invocation, records the artifact in `outcomeUnknownIds`, and does not retry or claim reclaimed bytes. A later invocation takes a new inventory. Artifact byte totals come from API metadata and are not a measurement of immediately updated GitHub billing storage. The [official artifact API](https://docs.github.com/en/rest/actions/artifacts?apiVersion=2022-11-28) defines listing, individual retrieval, and deletion; deleting artifacts requires Actions write permission.

## GHCR: inventory only

**Container deletion is disabled in this implementation**, including when package inventory becomes readable. On 2026-09-05 the existing authenticated package-list request returned HTTP 403, reported as `package_permissions_required`. The utility does not request or expose credentials, change token permissions, or attempt a different identity. If listing succeeds, the reason remains `oci_reference_graph_unverified`; every version is retained. Package counts and potential savings are `null` when unknown, rather than a misleading zero.

A future container cleanup implementation must preserve `latest`, `main`, `stable`, semantic-version/release tags, unfamiliar tags, and the newest three SHA builds. Only versions older than seven days with approved SHA/intermediate tags or no tags could be candidates. Before deleting any candidate, it must recursively prove that no retained OCI index references it, including architecture manifests and attestations. It must revalidate that proof before deletion. Without a complete, trustworthy graph or adequate permissions, it must continue skipping GHCR.

An untagged version is not evidence that an image is unused: multi-platform indexes and attestations reference separate manifests. See [Docker's attestation storage format](https://docs.docker.com/build/metadata/attestations/attestation-storage/) and [GitHub's package API permissions and version operations](https://docs.github.com/en/rest/packages/packages?apiVersion=2022-11-28). The current utility has no package DELETE endpoint at all.

## Running and scheduling

Use Python 3.10 or newer on macOS/Linux with `gh` already authenticated. It uses the existing credential store, fixed GitHub host, static endpoint allowlists, and argument arrays without a shell. Output contains a filtered JSON report; raw response bodies, headers, stderr, tokens, and environment variables are never printed. Responses are capped at 2 MiB while reading, stderr is discarded, and child processes are killed and reaped on overflow or timeout. Inventory is bounded to 20 pages / 2,000 records, with at most 200 HTTP requests and a shared 180-second request budget (20 seconds per request).

From the repository root:

```sh
# Read-only report; this is the default.
python3 tool/github_storage_cleanup.py

# Apply the reviewed policy, rechecking every candidate before deletion.
python3 tool/github_storage_cleanup.py --apply

# Optional smaller deletion budget; accepted range is 1..20.
python3 tool/github_storage_cleanup.py --apply --max-deletions 5
```

There is no generic repository/package selector, force option, or GHCR deletion flag. `candidateBytes` describes the initial eligible set; `deletedBytes` describes confirmed deletions. `remainingCandidates` counts initial candidates not deleted or skipped during apply. Status and reasons must be read separately for `artifacts` and `ghcr`. Exit code 0 means artifact processing completed, even when GHCR remains explicitly blocked; 1 means processing was blocked or interrupted, and 2 means invalid arguments. A partially completed apply can exit 1 and still list confirmed deletions.

The configured Codex heartbeat is **“Larenor geliştirme ve bakım”**. It wakes every 15 minutes to resume the approved development queue and preserves this daily maintenance at the first available wake after **03:15 Europe/Istanbul**, at most once per local calendar day. Before cleanup it checks the day's recorded result and afterwards records the dated outcome in local task state outside the repository. Its artifact deletion policy has not expanded. It runs on the configured Codex host, which must be available with the Codex app running, this checkout, Python, and its existing GitHub authentication. This is not a GitHub Actions cron workflow. The heartbeat follows this policy and reports meaningful cleanup, new failures, or required user action; unchanged package-permission status does not require repeated notifications. The scheduler is managed in Codex, not by this utility.

## Verification

Run the synthetic suite without contacting GitHub:

```sh
python3 -m unittest discover -s tool/tests -p 'github_storage_cleanup_test.py'
```

Tests exercise exact-name and signed/report protection, newest-three retention, complete/changing pagination, repository and completed-run binding, artifact/run/expiration races, deletion budgets, uncertain outcomes, protected container children and tags, static error redaction, endpoint restrictions, and bounded subprocess reads with synthetic flooding/dripping children.

The read-only implementation check on 2026-09-05 observed 176 artifacts (1,244,454,096 metadata bytes), with five eligible debug APKs (641,275,745 bytes) and 171 protected artifacts. No deletion was performed by that check. These are dated observations, not targets hardcoded into the utility; every subsequent run recomputes its inventory.

The first authorized apply on 2026-09-05 deleted those five debug artifacts with
confirmed HTTP 204 responses: **641,275,745 bytes**. A fresh complete inventory
then contained **171 artifacts / 603,178,351 metadata bytes**. The exact five
deleted IDs were absent, all three protected debug artifacts were present, and
every non-debug artifact from the previous inventory remained. GHCR versions
were unchanged. The full tool suite passed **157 tests**, including the 20
cleanup tests; these counts are not additive.
