# S09.1 final capture generation

Date: 24 September 2026

This slice closes the remaining implementation path for one immutable backup
generation across the Core database, vault key, configuration and managed
component payloads. It also binds the encrypted Client export receipt to that
same generation. Exact source `e84253208d8d2989e9f647fcdf13949d257c4e99`
passed the real amd64/arm64 privileged workflow and independent P1/P2 review.
After S08.8 and K07 merged, the production commits were rebased onto main
`21272df42801734eb5de87f101275344f0048340`; all nine stable patch IDs remained
identical. S09.1 is therefore `done`: the evidence-backed counters are
**30/125 (24.0%)** and **0/63 (0.0%)**.

## Job 1: immutable production generation

- RED `bfac0756` proves that managed snapshots cannot omit or mix generation
  identities.
- GREEN `5f776217` creates one 128-bit lowercase hexadecimal generation per
  quiesced capture, propagates it through the isolated worker descriptors and
  requires every component payload to match before the bundle is published.
- Hardening `b86e0a89` separates the generation grammar from other capture
  identifiers and rejects malformed worker output before authority is granted.

The manifest `snapshotId` is now the exact component capture generation. The
database, vault key and configuration are serialized during the same held
component lease, so no independently regenerated publication identifier can
hide a mixed cut.

## Job 2: interruption and two-architecture acceptance

- RED `bd98b73f` requires the privileged workflow to cover all generation
  owners and to prove restart recovery after publication is interrupted.
- GREEN `c0af6e20` extends the real Btrfs amd64/arm64 acceptance to retain one
  generation through descriptor publication, close it without a release
  acknowledgement, restart the engine, and remove the journal and capture
  tree. Existing partial-snapshot interruption and packaged-worker restart
  cases remain in the same workflow.

Schema/version drift still fails before publication through the existing
strict component contract. Cleanup remains generation-scoped, and startup
recovery cannot adopt a different journal or capture root.

## Job 3: exact encrypted Client receipt

- RED `02f519a6` requires the export route and Client stream to carry the exact
  generation receipt, including cancellation and partial-response cases.
- GREEN `1718ed37` returns `X-Larenor-Capture-Generation` from the encrypted
  Server publication and requires its exact lowercase format before the Client
  commits an OS-owned destination. The returned receipt combines the capture
  generation with the verified stream digest.
- Lifecycle coverage `0d30fccf` keeps a delayed otherwise-valid generation
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
  **58/58 PASS**.
- Targeted Dart analysis: **no issues found**.
- Native-workflow contract: **4/4 PASS**.
- Exact native CI [35952609533](https://github.com/ersingundem/larenor/actions/runs/35952609533):
  `linux/amd64` and `linux/arm64` PASS at source `e8425320`.
- Independent exact-source P1/P2 review: PASS; generation authority from the
  provider through worker, manifest, HTTP header and Client receipt is intact,
  while mixed/malformed generations and late/partial destinations fail closed.
- Ruff reports **0 diagnostics on added Python lines**; Dart format reports
  **0 changed files**.
- Repository security policy, execution-queue validation and commit-progress
  validation: PASS.

The exact-source `component-capture-native.yml` run passed on both architectures
and independent review found no P1/P2 blocker. S08.8 and K07 are already merged,
so the queue closure advances exactly one task. S09.2 restore and S09.3 clean
install/upgrade acceptance remain separate pending tasks.
