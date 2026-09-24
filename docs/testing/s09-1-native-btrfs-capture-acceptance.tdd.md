# S09.1 native Btrfs capture acceptance

## Scope

This third Linux capture slice binds the installed privileged worker
composition to the real amd64/arm64 Btrfs lifecycle. It does not change the
capability or snapshot implementation from Jobs 1 and 2, and it does not add
restore behavior.

## RED

`python3 -m unittest tool.tests.component_capture_native_workflow_test` failed
because restart recovery in the native fixture constructed
`LinuxCowCaptureEngine` directly. The installed
`larenor-component-backup-worker --check-config` composition was therefore not
part of the real interruption/recovery acceptance path.

## GREEN

The root-only native test now initializes the two durable installation
journals, creates an interrupted real read-only Btrfs snapshot generation, and
restarts through the installed worker entrypoint. Production composition must
revalidate the exact capture root capability, recover the journal and remove
the partial generation before startup succeeds. The source and capture root
are separately rooted, and the preflight receipt is issued for the production
capture root.

The path-scoped workflow already runs this test on GitHub-hosted Ubuntu 24.04
for both `linux/amd64` and `linux/arm64`. Local non-Linux execution reports the
single native fixture skip; the three static workflow contracts and the eight
non-native runtime tests pass.

## Exact-head review follow-up

The first published exact head failed the real fixture on both architectures
in run `35943603923`. A permanent diagnostic RED at `b9b2a1c8` narrowed run
`35943852806` to the generic mount observer's device-number check: Linux had
already proved root authority, `CAP_SYS_ADMIN`, the initial user namespace,
the exact directory descriptor and its unique mount ID, but a Btrfs mount can
report a backing-device number in `mountinfo` that differs from the directory
descriptor's anonymous Btrfs `st_dev` value.

The deterministic RED at `b5cfbcdd` requires the generic observer to remain
strict for every filesystem and rejects invalid opt-in values. GREEN
`9569150f` adds one explicit Btrfs-only option used by the privileged capture
preflight. Exact mount ID, two identical mount snapshots, retained descriptor
identity, process root, mount namespace, calling thread and deadline checks
remain mandatory; even with the option enabled, a mismatched non-Btrfs device
still fails closed. The focused mount-observation and capture-preflight suites
pass locally. Real amd64/arm64 execution remains the exact-head merge gate.

S09.1 remains pending. Queue progress stays at **26/125** and selected-feature
progress stays at **0/63**; complete generation and platform acceptance remain
milestone gates.
