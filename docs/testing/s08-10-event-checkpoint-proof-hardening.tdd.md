# S08.10 transfer event checkpoint proof hardening

The exact `07cea8a7` acceptance was audited across event history, resume/cancel,
authority/lifecycle, and tablet state language. Resume/cancel and the EN/TR
600/1200 2x UI matrix remain sound. The audit found one integrity blocker in
the durable event checkpoint.

## Root cause

The device retained only the scoped `chainId` and `headSequence`. After a valid
Core snapshot rollback, a different branch could reach the same sequence under
the same persistent chain ID. An incremental read from that sequence was empty,
so the Client had no opaque proof that the retained prefix still matched.

The upgrade audit also found that changing the secure-storage key from v1 to
v2 silently ignored an existing trusted v1 chain/sequence anchor. The first
post-upgrade response could therefore become a new trusted baseline even when
it was behind the retained sequence.

## Acceptance

1. Core derives HMAC-bound cursor, page, and head checkpoints from the exact
   caller/resource-visible event prefix and returns all three on every bounded
   page.
2. Client checkpoint v2 binds Core/home/resource/account/role, chain, sequence,
   and the opaque head checkpoint. Restart and pagination require exact cursor
   continuity; same-sequence divergence fails as rollback without replacing the
   retained proof. A same-scope v1 record is read as a migration anchor; its
   chain and sequence must pass the next Core read before a v2 proof is written.
3. Existing resume/cancel semantics, lifecycle retirement, 48dp keyboard and
   TalkBack actions, EN/TR 600/1200 2x layouts, and stored/reachable/verified
   state language remain green.

## TDD evidence

RED was captured in commit `7db0ff00`: the Client rejected the new strict proof
fields and the exact event test could not observe a cursor/head proof. GREEN is
validated by the bounded Server suite and the four focused Flutter API,
controller, checkpoint, and tablet suites recorded in the final branch report.
Upgrade RED is captured in `825554b9`: a valid v1 record was skipped, history
started from a null cursor, and the controller could re-anchor below the saved
head. The migration test now proves rollback stays untrusted and a valid
same-chain read is the only path that writes v2.

Progress remains 17/125 and 0/63; physical SAF/device validation is still the
existing completion gate.
