# S09.1 final capture generation

Date: 24 September 2026

This slice closes the remaining implementation path for one immutable backup
generation across the Core database, vault key, configuration and managed
component payloads. It also binds the encrypted Client export receipt to that
same generation. S09.1 remains `awaiting_ci`: independent review and the real
amd64/arm64 privileged workflow are still required before queue completion.
The evidence-backed counters therefore remain **27/125** and **0/63** in this
branch. Queue and progress ledgers are intentionally unchanged while the S08.8
and K07 completion changes remain ahead in the merge order.

## Job 1: immutable production generation

- RED `66f7e3fc` proves that managed snapshots cannot omit or mix generation
  identities.
- GREEN `64c5869e` creates one 128-bit lowercase hexadecimal generation per
  quiesced capture, propagates it through the isolated worker descriptors and
  requires every component payload to match before the bundle is published.
- Hardening `ae63978b` separates the generation grammar from other capture
  identifiers and rejects malformed worker output before authority is granted.

The manifest `snapshotId` is now the exact component capture generation. The
database, vault key and configuration are serialized during the same held
component lease, so no independently regenerated publication identifier can
hide a mixed cut.

## Job 2: interruption and two-architecture acceptance

- RED `ec2f3261` requires the privileged workflow to cover all generation
  owners and to prove restart recovery after publication is interrupted.
- GREEN `be952d0d` extends the real Btrfs amd64/arm64 acceptance to retain one
  generation through descriptor publication, close it without a release
  acknowledgement, restart the engine, and remove the journal and capture
  tree. Existing partial-snapshot interruption and packaged-worker restart
  cases remain in the same workflow.

Schema/version drift still fails before publication through the existing
strict component contract. Cleanup remains generation-scoped, and startup
recovery cannot adopt a different journal or capture root.

## Job 3: exact encrypted Client receipt

- RED `1b49dd2b` requires the export route and Client stream to carry the exact
  generation receipt, including cancellation and partial-response cases.
- GREEN `5d2e0192` returns `X-Larenor-Capture-Generation` from the encrypted
  Server publication and requires its exact lowercase format before the Client
  commits an OS-owned destination. The returned receipt combines the capture
  generation with the verified stream digest.
- Lifecycle coverage `9ab39a03` keeps a delayed otherwise-valid generation
  response valid at the transport layer, proving route retirement itself owns
  the cancellation result.

Missing or malformed generation headers cancel the destination without a
commit. Account, Core, route and controller generation drift still abort the
transport and suppress late publication; no raw key, token or passphrase is
added to the URL, response metadata or receipt.

## Local evidence

- `uv run --project server pytest -q server/tests/test_core_backup*.py`:
  **319 collected**, PASS with **2 expected native skips** on macOS.
- Flutter Core-backup API/controller/screen/source/destination group:
  **50/50 PASS**.
- Targeted Dart analysis: **no issues found**.
- Native-workflow contract: **4/4 PASS**.
- Ruff reports **0 diagnostics on added Python lines**; Dart format reports
  **0 changed files**.
- Repository security policy, execution-queue validation and commit-progress
  validation: PASS.

The merge gate remains the exact-head `component-capture-native.yml` run on
both `linux/amd64` and `linux/arm64`, plus independent review. Only a later
evidence commit after those gates and the preceding S08.8/K07 merges may mark
S09.1 complete and advance the queue counter.
