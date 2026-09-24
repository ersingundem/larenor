# S09.2 offline Core and component restore evidence

Status: implementation pending exact-head CI and independent audit. S09.2 stays
open at `30/125` queue items and `0/63` feature checklist items.

## Three production jobs

1. `f313e196` composes an explicit root-only offline runtime from the durable
   installation journals, exact Docker endpoint, descriptor-bound Linux restore
   engine, private 32-byte recovery key, and authenticated v3 recovery journal.
   Construction performs no Docker or host-volume effect.
2. `a6248b05` stages Core off-target and persists one `pending` decision before
   component work. Core files cannot publish until the component coordinator
   has durably released the exact authority generation. An interrupted run
   keeps normal startup closed and an exact authenticated retry reconciles the
   component journal before publishing Core.
3. `d38d9d30` wires the contract into the packaged `larenor-server --restore`
   path and the required linux/amd64 plus linux/arm64 native workflow. Runtime
   authority must be complete; provider paths and the passphrase remain private
   files rather than CLI values.

Two fail-closed follow-ups are part of the same delivery. `917e4342` proves
privileged runtime construction before either restore input is read and maps
runtime/plan failures to static output. `61ddeb04` makes every new production,
CLI, and product-recovery input trigger the dual-architecture native gate.
`b85af698` adds a root Linux journey which invokes the packaged CLI against a
synthetic Unix Engine, publishes the real descriptor-bound volume trees, opens
the restored Core, verifies release, and runs independently on both matrix
architectures.

## RED to GREEN

- `fd2d2388` failed collection because the packaged component restore runtime
  did not exist; `f313e196` made its eight composition and rejection cases pass.
- `1325fa79` failed because `restore_empty` had no component authority or shared
  recovery decision; `a6248b05` made both publication-order and retry journeys
  pass while retaining the existing empty-Core regressions.
- `d8ed7010` failed because the CLI had no component authority options and the
  native matrix omitted product/runtime tests; `d38d9d30` added both surfaces.
- `6f3e33a5` proved that CLI secrets were read before privilege; `917e4342`
  reversed that ordering.
- `20df24bf` proved the native scope classifier could skip all four new product
  inputs; `61ddeb04` closed that false skip.
- `947c2b35` required a true root CLI-to-Core-and-volume journey rather than a
  mocked CLI seam; `b85af698` added its dedicated dual-architecture execution.

## Security boundary

The normal HTTP server never constructs restore authority. A component restore
requires a separate root process, operator-owned absolute paths, private
journals/key, exact Docker peer verification, current durable installation
authority, and a finite five-minute CLI deadline. Component payloads remain
rejected when this runtime is absent. A `pending` Core journal is intentionally
unbootable; only the component coordinator's durable `released` checkpoint can
change it to the publishable decision. Errors do not include host paths,
payloads, passphrases, Docker responses, or receipt contents.

## Required verification

The grouped local package covers runtime/config rejection, Core publication
ordering, crash retry, existing empty-Core recovery, CLI secret handling,
Linux descriptor publication, Docker authority, component planning/staging,
and authenticated v3 reconciliation. The native workflow repeats the product
runtime and CLI journeys together with real `renameat2`, `SIGKILL`, ownership,
rollback, and durable-authority tests on both production architectures.

Exact-head CI and independent review evidence are deliberately absent here;
they must be attached before the queue item can close.
