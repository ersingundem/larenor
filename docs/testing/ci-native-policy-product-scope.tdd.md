# Native-policy product CI scope

20 September 2026. This policy slice prevents native-characterization workflow
maintenance from reserving unrelated Android and Server test capacity.

## Acceptance criteria

1. Changes limited to the six reviewed managed-characterization workflows,
   `native_ci_scope.py`, or its policy test reuse Android evidence.
2. The same exact native-policy-only set reuses Server evidence while the native
   workflows retain their own required check names and fail-open scope gate.
3. Unknown workflow/tool paths, mixed product changes, invalid revisions, empty
   diffs, manual runs, and diff failures continue to execute the affected
   product suites.

The RED policy tests first demonstrated both Android and Server false positives.
The GREEN implementation uses an exact eight-path allowlist rather than a broad
workflow or `tool/**` exception. Seventeen Android, Server, and native-scope
policy tests pass; compile, diff, progress, and merge-tree checks are clean.
This optimization does not change queue or selected-feature completion; the
accepted `67261f69` baseline is **17/125** and **0/63**.
