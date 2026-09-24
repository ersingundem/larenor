# S09.1 Btrfs descriptor-bound effects

## Scope

This follow-up closes the remaining path-swap race in the privileged Linux
capture engine. It does not add restore behavior or change queue counters.

## RED

The first focused regression failed because `LinuxBtrfsCapturePreflight` did
not expose its retained capture-root descriptor. The prior backend also passed
visible source and destination paths to `btrfs`, so a path could be replaced
during the native effect and restored before the later identity check.

The permanent adversarial regression swaps both visible source and generation
paths during snapshot creation, read-only inspection, and deletion. It proves
that every native operation still receives the original descriptor identities.

## GREEN guarantees

The engine now retains the exact capture-root and source directory descriptors
across every mutating phase. Generation creation, snapshot open, enumeration,
cleanup, and removal use validated relative IDs with `dir_fd`. The backend
accepts only exact directory descriptors plus a 32-character capture ID and
invokes fixed `btrfs` operations through `/proc/self/fd`, with the required
descriptors explicitly inherited through `pass_fds`.

Focused preflight, engine, and composition result: **53 passed**. The milestone
component-capture package ran **203 tests: 201 passed and 2 explicit native
fixture skips**. The three static amd64/arm64 workflow contracts passed.

S09.1 remains pending at **26/125** queue progress and **0/63** selected-feature
progress.
