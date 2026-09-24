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

S09.1 remains pending. Queue progress stays at **26/125** and selected-feature
progress stays at **0/63**; complete generation and platform acceptance remain
milestone gates.
