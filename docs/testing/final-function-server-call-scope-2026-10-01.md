# Reusable Server workflow scope — 1 October 2026

## Failure

Android Build run `36808321597` at exact revision
`fecc51c812aedb00fda8e4a976fb04b2df11fe8f` called
`.github/workflows/server-test.yml` as a reusable workflow. The caller itself
was started with `workflow_dispatch`, so the called workflow retained that
event name. `workflow_call` did not declare `scope`; consequently
`inputs.scope` was empty and all four Server shards, the F08 Linux cgroup job,
the host-worker Linux job, and their required aggregate were skipped by their
manual-scope conditions.

## Repair

The reusable contract now declares an optional string `scope` with default
`all`. Existing callers such as Android Build need no `with` block and select
all required Server gates even when the outer workflow was manually
dispatched. Direct manual runs keep their constrained choice input, so
`f60-host`, `f60-discovery`, and `f60-stream` still select only their exact
provider workflow. The required aggregate retains its exact dependencies on
the four Server shards, F08 cgroup proof, and host-worker proof.

## Evidence

`tool/tests/server_test_workflow_test.py` resolves the reusable default and
evaluates the workflow's actual job conditions. Before the repair its default
selection test failed because `workflow_call.inputs.scope` did not exist. The
fixed test requires all required jobs and the aggregate for an omitted called
scope, and separately requires each explicit F60 scope to select only its
registered reusable provider job. Syntax is checked with `actionlint`; no
host, provider, or household operation is performed by this local gate.

Root independently passed the 10 Server workflow/scope tests and `actionlint`
for both Server and Android workflows. The changed-source hosted run remains
required; the skipped aggregate from the earlier run is not accepted.

The optional string/default contract follows the
[GitHub workflow input specification](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#onworkflow_callinputs).

The same old run's analysis job `110197544773` failed formatting before
analysis. Only its two named files were formatted:
`test/features/multi_display/dual_display_authority_api_test.dart` and
`test/features/power_budget/power_budget_normal_core_test.dart`.
Root repeated `dart format --output=none --set-exit-if-changed` on those
exact paths: zero changes, exit zero. Their test behavior was not changed.
