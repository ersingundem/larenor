# S09.1 packaged Linux COW capture worker

Date: 24 September 2026

This slice packages the existing authority-bound isolated capture lease as a
real privileged Server worker and supplies the smallest Linux btrfs capture
engine needed by that boundary. It does not implement restore (S09.2), clean
installation or upgrade recovery (S09.3), and it does not close S09.1. Queue
progress remains **26/125** and selected-feature progress remains **0/63**.

## Three delivered jobs

1. **Packaged composition.** The
   `larenor-component-backup-worker` entrypoint opens the durable managed
   container and volume journals, constructs the installed-authority view,
   binds a fixed Docker Unix endpoint to `UnixDockerComponentSnapshotAdapter`,
   installs the native capture engine, and exposes the existing peer-checked
   component worker socket. It rejects non-root production startup, unsupported
   platforms, ambiguous paths and invalid UID/GID values. RED `fbe7328b`;
   GREEN `a083bca6`.
2. **Read-only COW engine and restart journal.** The engine journals the exact
   complete generation before the first btrfs effect, uses only fixed
   `subvolume snapshot -r`, `property get ... ro` and `subvolume delete`
   operations through a root-owned executable, and returns held read-only
   directory descriptors. Source path/inode drift, writable snapshots,
   malformed journals, unjournaled capture-root entries and expired deadlines
   fail closed. Release removes the journal only after every snapshot is gone;
   interruption deliberately retains it for bounded startup recovery.
3. **Two-architecture native acceptance.** The path-scoped
   `component-capture-native.yml` job creates an ephemeral btrfs filesystem on
   GitHub-hosted Ubuntu 24.04 amd64 and arm64 runners. It executes the installed
   console entrypoint, a real read-only snapshot/read/release cycle, and a
   forced interruption followed by journal-driven cleanup. The pinned
   `btrfs-progs=6.6.3-1.1build2` package is common to both architectures.

## Local evidence

The focused implementation batch passed **15/15**. The grouped component
backup package passed **103 tests** with the single native test explicitly
skipped outside its root-owned btrfs fixture; two static workflow tests passed.
Ruff format/check, Python compilation, repository security policy, execution
queue validation and `git diff --check` passed on the final local tree.

The native workflow is the acceptance source for actual btrfs behavior. Local
fake-backend tests prove malformed journal, source replacement, unjournaled
root, writable snapshot, release failure and restart cases without claiming a
host filesystem result.

## Remaining S09.1 boundary

S09.1 still requires one exact generation spanning database, vault key,
configuration and component data, plus the full backup contract and retention
evidence. Restore, rollback and clean-install recovery remain outside this
slice.
