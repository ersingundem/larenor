# Native-policy product CI scope

20 September 2026. This policy slice prevents native-characterization workflow
maintenance from reserving unrelated Android and Server test capacity.

## Acceptance criteria

1. Changes limited to the six reviewed managed-characterization workflows or
   the unified package's exact workflow, planner, bundle, runner and policy
   paths reuse Android evidence. Each of the five component characterizers also
   derives its own closed native input set from the exact GitHub workflow ref;
   unrelated Core domains such as inventory no longer reserve every matrix.
2. The same exact native-policy-only set reuses Server evidence while the native
   workflows retain their own required check names and fail-open scope gate.
3. Unknown workflow/tool paths, mixed product changes, invalid revisions, empty
   diffs, manual runs, and diff failures continue to execute the affected
   product suites.

The RED policy tests first demonstrated both Android and Server false positives.
The GREEN implementation uses an exact native-policy allowlist rather than a
broad workflow, `deploy/**` or `tool/**` exception. Unknown, malformed or foreign
workflow refs fail open and `tool/native_ci_scope.py` changes still repeat every
component matrix. Nineteen Android, Server, and native-scope policy tests pass;
compile, diff, progress, and merge-tree checks are clean.
This optimization does not change queue or selected-feature completion; the
accepted `2169dd6f` baseline is **17/125** and **0/63**.
