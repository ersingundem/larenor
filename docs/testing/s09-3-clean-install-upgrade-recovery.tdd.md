# S09.3 clean install, upgrade, and recovery evidence

Date: 2026-09-24

Status: `done`. PR #491 exact source
`8113e8e456f36abca19b2eb8e3d4296a60faeef4` passed current-head CI and was
squash merged as `b7a82258f11a6bd46f00d9a8561dcb2b895fb030`. The prior
exact `69173ecdda045a97c99d1e65256b950e3c581a10` stopped both native
architecture jobs before pull/create with `unified_preflight_failed`: the
production manifest requires 147456 MiB on the same device while the standard
hosted runners provide about 14 GiB. The current exact retains that failure as
diagnostic history and adds an acceptance-only per-device capacity fixture;
production `LocalHostFacts` and deployment policy are unchanged. Exact
`84f4abdf86290011a2733014d606ada5c7d1a056` then exposed a bounded
`unified_install_reconcile_failed`. Exact `3007994b` preserved the original
allowlisted lifecycle-stage code when reconcile itself failed, but native run
`36040926865` showed that an empty reconcile result was still remasked during
receipt validation. The current exact preserves the original bounded code in
that path too; unknown errors and malformed non-empty receipts remain the
static reconcile code without private details. Run `36041571640` then exposed
the exact `unified_manifest_invalid` root: archived Compose reports an absolute
base build context with a relative Dockerfile. The current exact resolves only
the literal `server/Dockerfile` from the canonical archived context and rejects
absolute, traversal, foreign and symlinked source paths. This document
also records that fresh-process ownership adoption rerenders exact current
Compose config under the retained project identity, and that public phase
runtime receipts bind their digests, current Core continuity and external
component container receipts without inventing a base-phase outer proof. Source and squash aggregate stable patch-id
`9b614a3dcf5e3703ab6ee953956acfd4afeb5d3f` matched, and the squash commit is
in `origin/main` ancestry.

## Accepted software boundary

The proposed source connects four existing S09.3 slices into one bounded
software acceptance:

1. Exact installed-state preflight distinguishes an empty owned root from an
   upgrade, validates the full production receipt against the archived bundle,
   and rejects foreign roots, descriptors, links, devices and host-fact races.
2. The Client exposes only read-only source inspection under the current admin,
   account and route generation. The proof contains bounded magic and size
   facts; URI, path, bundle bytes, token and full digest stay out of the UI. The
   proof is explicitly not restore authority and is retired on route disposal
   or account replacement.
3. Packaged public health re-reads Core and every managed component after
   restart and rejects malformed, foreign or mismatched source, manifest,
   platform, image and container receipts. Running state alone is not accepted
   as health.
4. The native acceptance materializes the exact ancestor from Git objects,
   performs a clean base install, recreates the reviewed current version,
   injects a post-effect process exit, and reconciles it in a fresh process
   without replay. Every persistent writable Core/component mount has a random
   bounded sentinel proof. Cleanup is deferred until exact receipt verification
   and is limited to descriptor-revalidated owned roots.

No production automation or home device is mutated by this acceptance. The
dual-architecture jobs operate only on disposable GitHub-hosted environments.

## RED to GREEN evidence

- Installed-state and host-fact RED/GREEN range:
  `9a0cdf41b54c7303a37db546de65c4addf6aaf41` through
  `628955aec7e49f7c72e174d247a6199ae3fca173`.
- Client source-inspection RED/GREEN range:
  `ea34458c948265e90e4c5b83c593d2526721866b` through
  `b13349f91329805c326f9abb2fe23774e660a0c0`.
- Packaged health RED/GREEN range:
  `7488a138349cde7088e0442b9f5fd33cdb585232` through
  `aecb951418f2d22d11fc6ee24ed706f6ee83645f`.
- Native install/upgrade/recovery source ends at
  `8113e8e456f36abca19b2eb8e3d4296a60faeef4`. The acceptance wrapper delegates
  real architecture, installed state, clean-root, kind, UID, mode and device
  facts and floors only `availableMiB` to the exact required sum per observed
  device. Its public receipt is explicitly `contract_fixture` and
  `capacityVerified=false`.

The committed exact tree passed 64 grouped deployment, runtime, bundle,
install/upgrade, workflow and native-scope tests. The Client backup screen
passed 12 widget tests, including English/Turkish 600/1200 layouts, digest
redaction, account retirement and route-disposal late-result rejection.
Security policy, Python compilation, commit progress and diff checks passed.
Two independent exact-source audits found no P1/P2 blocker.

## Exact-head gates

- Android Build: `36045880167`, passed on attempt 2. Failed-only Server shard-3
  job `107796968207` and aggregate job `107801997329` passed; static analysis,
  Flutter shards, debug APK and API 35 emulator also passed.
- Security: `36045879756`, passed.
- Unified Media Stack Native Acceptance: `36045879876`, including passed
  `linux/amd64` job `107789265813` and `linux/arm64` job `107789265906`.

The superseded native run `36038916185` remains diagnostic evidence: its
contract suite passed 59/59 on both architectures, then both lifecycle jobs
failed the real same-device capacity preflight before any pull/create effect.

S09.3 is `done`; queue progress is **34/125 (27.2%)** and selected-feature
progress remains **0/63**. The production capacity policy was not lowered to
fit a hosted runner. Production automation and physical home-device mutation
remain outside this software acceptance.
