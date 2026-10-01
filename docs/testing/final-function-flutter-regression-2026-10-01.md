# Full Flutter regression — 1 October 2026

The Dart application and test tree at `b21eb4a733e7c74074513ea720b5fd70a3824169` completed the full local Flutter machine run. No Dart, localization, generated Dart, or Flutter test source changed during this run. Concurrent native/Python work is outside this test claim.

```text
flutter test --no-pub --machine --concurrency=2 --timeout 90s
flutter analyze --no-pub
dart format --output=none --set-exit-if-changed .
```

| Check | Actual result |
| --- | --- |
| Visible Flutter test cases | **7,919 passed; 57 skipped; 0 failures** |
| Terminal machine event | `done.success=true`, elapsed 1,096,713 ms |
| Full analyze | No issues found |
| Full Dart format | 1,981 files, 0 changes |

Hidden loading events are excluded from the case count. The [bounded summary](final-function-flutter-regression-2026-10-01.json) records each skipped test file and its count. Those opt-in normal-Core and SSH fixture cases require their explicit isolated runner environment; they are **not accepted by this default full run**. Their named integration evidence remains separate in the [feature matrix](final-function-feature-matrix-2026-09-30.md). No household device or provider was written by this run.

The auxiliary summary helper raised `AttributeError` after Flutter completed because some application output lines decode to JSON lists. Root rebuilt the summary independently, ignoring non-object output and checking the actual terminal machine event. Flutter was not rerun to hide that collector error.

Private machine log: `/private/tmp/larenor-flutter-full-root-20261001.machine.jsonl`, SHA-256 `014b580d1edd3339dbf179c1a5d97e2c39e2d64fd65c72b58d87d3aad939203e`. The analyzer and formatter logs are private too.

This is local Dart regression evidence. It does not establish the changed Kotlin/native source, actual Android device behavior, current required hosted CI, or F60/F62 stream acceptance. The Flutter Client currently has no general web build target; the separately scheduled Core web UI is still pending after all final steps.
