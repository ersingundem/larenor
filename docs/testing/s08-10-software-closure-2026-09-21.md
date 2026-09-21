# S08.10 software closure

21 September 2026. S08.10 is closed as a software task after its bounded
command, event, download, upload, receipt, resume, cancel, and durable checkpoint
chain was merged and hardened on `main`. Physical device and local-network
acceptance remains separately tracked by `MANUAL.TABLET` and
`MANUAL.SERVICES`.

## Final acceptance criteria

1. **Bounded and authorized transfer.** Core validates actor, resource, ACL,
   service revision, request identity, media type, declared length, digest, and
   byte limit before content becomes trusted. Upload and download receipts
   distinguish completed, interrupted, resumed, cancelled, and conflicting
   replays across restarts.
2. **Verifiable event continuity.** Server event pages expose a caller-scoped
   HMAC chain with bounded pagination. Client checkpoints bind Core, home,
   resource, actor, role, sequence, and head proof; rollback, divergence,
   malformed storage, retired sessions, and late responses fail closed.
3. **Usable Android lifecycle.** The tablet flow keeps stored intent,
   reachable service, provider acceptance, and device-observed result distinct.
   EN/TR state, resume/cancel, route and account changes, and lifecycle races are
   covered without treating a stale response as success.

## Exact evidence

- PR [#179](https://github.com/ersingundem/larenor/pull/179) merged the complete
  software chain. Its exact head `d42bb3fa` passed the required Android Build
  run [35522856631](https://github.com/ersingundem/larenor/actions/runs/35522856631),
  including static analysis, Flutter, Server, Android build/signature, and
  emulator jobs.
- PR [#233](https://github.com/ersingundem/larenor/pull/233) added divergent
  replay and v1-to-v2 checkpoint protection. Its exact head `5df2584d` passed
  Android Build run
  [35541864163](https://github.com/ersingundem/larenor/actions/runs/35541864163)
  together with security and native acceptance workflows.
- Current `main` at `c08020dd` passed **67 Server tests** across the bounded
  transfer, provider, receipt, upload, authority, event, and command-history
  suites; **58 Flutter tests** across transfer contracts, framed downloads,
  product blobs, media preflight, HA checkpoints, and transfer-event
  checkpoints; and targeted Flutter static analysis with no issues.
- Independent authority and lifecycle review found no remaining software
  blocker. It checked pre-provider authorization, exact receipt identity,
  encrypted checkpoint scope, v1 migration anchoring, sequence rollback,
  chain replacement, stale response rejection, and retained-cursor behavior.

## Boundary

This closure does not claim a physical Huawei, DeX, Android SAF, or real-home
LAN result. Those environment-dependent checks stay visible under the manual
tablet and service acceptance tasks and do not block the completed software
contract.
