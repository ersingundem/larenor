# S09.1 Linux capture authority hardening

## Scope

This follow-up closes two independent review findings in the privileged Btrfs
capture boundary. It does not add restore behavior and does not change the
queue or selected-feature counters.

## RED

The focused package initially failed at collection because no strict host UID
map parser existed. The new behavioral regressions also required guarantees
that the prior implementation did not provide:

- an ancestor symlink must fail the production directory opener;
- remapped root and user-namespace or mount-namespace drift must invalidate the
  exact capability receipt;
- the capture-root descriptor must remain open for the worker lifetime;
- the source descriptor must remain open across the Btrfs snapshot effect;
- authority loss before generation creation must preserve the journal without
  dispatching a snapshot mutation.

## GREEN guarantees

The production opener walks every absolute path one component at a time with
`openat`, `O_NOFOLLOW`, `O_DIRECTORY`, `O_RDONLY`, and `O_CLOEXEC`. Every
ancestor is a non-writable root-owned directory. The exact capture-root FD is
retained until runtime shutdown, while a source FD is retained across each
snapshot operation and compared with a fresh path FD after the effect.

The capability receipt now binds `/proc/thread-self/status`, the initial-host
`uid_map`, and `/proc/thread-self/ns/user` identity in addition to the exact
Btrfs mount and mount namespace. Remapped root, namespace drift, root/path
replacement and authority loss all fail closed. Capability checks bracket the
journal, generation-directory and Btrfs mutation phases; an unsafe cleanup
keeps the durable journal for a later trusted restart.

Focused result: **52 passed**. The milestone component-capture package ran
**200 tests: 198 passed and 2 explicit native-fixture skips**; the three static
amd64/arm64 workflow contracts passed. Real privileged Btrfs behavior remains
owned by the two-architecture native workflow.

S09.1 remains pending at **26/125** queue progress and **0/63** selected-feature
progress.
