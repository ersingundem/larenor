# S08.10 exact software acceptance evidence

20 September 2026. This local-only integration branch composes the completed
S08.10 software slices on one exact commit. It records the final software
criteria and the remaining release gates without changing queue or selected
feature counters.

## Exact composition

The acceptance branch is rebased on exact main `b38c8ab9` and replays these
independently developed slices before the final RED/GREEN slice:

| Slice | Exact head | Local composition commit |
| --- | --- | --- |
| Android transfer state, SAF preflight, and media upload protocol | `7c0e7f50` | `4104d2ff` |
| Shared bounded-transfer contract | `54a1fea7` | `afda1a96` |
| HA Client event checkpoint | `03921638` | `dacbb09c` |
| Server transfer event chain | `acc0a426` | `a875648d` |

`867ddc2c` is the rebased RED commit for the missing transfer-event consumer and
secure checkpoint. The tests failed on the intentionally absent API, persistence,
and controller symbols. `5cda918f` is the rebased GREEN implementation commit.

## Final three integration criteria

1. **Closed event protocol.** Android parses the bounded transfer-event page
   only when its Core/home/resource target, stable chain, monotonic sequence,
   allowed event kind, and embedded receipt state agree. Pagination cannot
   skip, repeat, change chain, or claim an invalid head.
2. **Durable scoped trust.** The encrypted checkpoint is bound to Core, home,
   resource, actor, and role. Restart resumes from the retained `after` cursor;
   rollback, chain replacement, concurrent conflict, malformed storage, and
   retired lifecycle fail closed without advancing it.
3. **Proof-gated history.** Transfer history becomes current and visible only
   after every returned event agrees with its receipt and the checkpoint
   advances. Failed refresh clears current trust while retaining the last
   cursor for comparison. The EN/TR tablet UI exposes the verified cursor.

These criteria join Server authority/order, binary framing, upload, product
provider, durable receipt, shared contract, Client SAF preflight, state
language, and command-event checkpoint behavior on the same local tree. No
software-only acceptance gap remains in the S08.10 matrix on this composition.

## Exact local verification

| Surface | Command scope | Result |
| --- | --- | --- |
| Android transfer integration | transfer event checkpoint, framed download, controller lifecycle, tablet UI, shared contract | **52 passed** |
| Android HA event integration | secure HA checkpoint and synthetic HTTP lifecycle/restore integration | **10 passed** |
| Server transfer integration | event chain, media upload, shared contract, product provider, framing, receipt, and authority order | **58 passed** |
| Static analysis | owned `home_resources` and `core_ha` source plus checkpoint/contract integration tests | **No issues** |

The focused runs have no skips. The Server run emits only upstream
Starlette/httpx and AnyIO deprecation warnings.

## Independent authority and lifecycle review

The integration pass found and closed two Client trust gaps before publication:

- migrated Server chains may contain an `accepted` baseline followed by the
  restart recovery result; the Client now accepts that exact baseline shape
  instead of rejecting a valid upgrade history;
- a member checkpoint now rejects every event whose actor differs from the
  active session user, while the administrator view keeps its documented
  multi-actor scope.

The focused checkpoint suite covers both regressions together with scope,
rollback, chain replacement, lifecycle retirement, restart cursor reuse, and
failed-proof trust clearing. All three tests pass and targeted static analysis
is clean. The rebased authority fixes end at `b3178dc1`. Queue and selected-feature
counters remain unchanged until the closing sequence below completes.

## Required closing sequence

S08.10 remains `pending`, with counters fixed at `15/125` and `0/63`, until all
of the following are true:

1. the prerequisite slice heads are reviewed and merged;
2. this final slice is replayed or rebased onto that exact `main` without
   weakening its RED/GREEN evidence;
3. required GitHub CI passes on the exact resulting head and an independent
   authority/lifecycle review accepts it; and
4. real LAN/service and physical Huawei tablet, DeX, and Android SAF checks are
   recorded under `MANUAL.SERVICES` and `MANUAL.TABLET`.

Only after those gates may the queue validator accept S08.10 as `done` and the
progress counters advance.
