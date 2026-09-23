# S09.1 restore configuration compatibility

Date: 23 September 2026

The encrypted Core bundle already carries a canonical configuration resource
that records whether each privileged worker boundary was enabled at capture
time. Empty-target restore authenticated that resource but ignored its worker
topology, so it could publish a backup into a target with a different
installation, Keenetic, plugin, or Proxmox execution surface.

## Acceptance boundary

1. Restore compares the four backed-up worker-presence flags with the target's
   current `Settings` before creating staging files or publishing any state.
2. An exact topology remains accepted. Any enabled/disabled drift fails with
   the existing static `backup_incompatible` classification and leaves no
   database, key, journal, or stage behind.
3. Socket, health, key-file paths, UIDs, and other host-local values are not
   added to the bundle or error surface. This slice defines compatibility for
   the existing boolean configuration contract; it does not claim to migrate
   privileged host paths or credentials.

## TDD evidence

The RED test exported a real bundle with all four workers disabled, then
restored it into a target with a plugin worker enabled. The old implementation
completed restore instead of rejecting the configuration mismatch. The GREEN
regression parameterizes installation, Keenetic, plugin, and Proxmox worker
boundaries and proves each mismatch is rejected before staging.

The focused configuration, empty-Core restore, and component backup suites pass
**24 tests** with only the two existing Starlette/httpx deprecation warnings.
Focused Ruff and bytecode compilation pass for the changed Server surface.
Repository policy, security, queue, progress, and diff checks are run again on
the final commit.

## Remaining S09.1 gates

S09.1 remains pending. Host-local configuration migration policy, production
component restore and rollback, interruption recovery across component effects,
native/provider acceptance, independent review, and exact-head CI remain
separate gates. This slice does not change `docs/PROGRESS.md`,
`docs/execution-queue.json`, or the counters **26/125** and **0/63**.
