# S09.1 restore CLI I/O errors

Date: 23 September 2026

The offline restore CLI already validated private-file permissions, bundle
bounds, and the shared passphrase contract. Raw filesystem errors still escaped
the CLI when an input disappeared or storage failed during restore, exposing an
absolute private path through an exception or process traceback.

## Acceptance boundary

This narrow Server slice closes three offline failure stages:

1. A missing or unreadable bundle returns the static
   `restore_input_unavailable` initialization error without its path.
2. A missing or unreadable passphrase file returns the same static input error
   without its path or secret-bearing filename.
3. An `OSError` while publishing the restore or reopening the restored Core
   returns `restore_storage_unavailable` without stage, data, or key paths.

Existing `ApiError` and `StartupError` classifications remain unchanged.
Private-file permission and symlink validation still fail through their current
static errors, and successful restore still reopens the Core before reporting
completion. No bundle bytes or passphrase value is added to output.

## TDD evidence

Four RED cases raised raw path-bearing exceptions for a missing bundle, missing
passphrase file, restore publication failure, and post-restore reopen failure.
The GREEN CLI maps only `OSError` at the input and storage boundaries, preserving
all semantic backup errors.

The focused new regressions pass **4 tests**. The broader CLI-secret,
empty-target restore, and recovery-preflight batch passes **24 tests** with only
the two existing Starlette/httpx deprecation warnings. Focused Ruff and bytecode
compilation pass. The repository policy suite passes **383 tests** with four
documented native-fixture skips; security, queue, progress, and diff checks also
pass.

## Remaining S09.1 gates

S09.1 remains pending. Production component restore and rollback, interruption
recovery across component effects, native/provider acceptance, independent
review, and exact-head CI remain separate gates. This slice does not change
`docs/PROGRESS.md`, `docs/execution-queue.json`, or the counters **26/125** and
**0/63**.
