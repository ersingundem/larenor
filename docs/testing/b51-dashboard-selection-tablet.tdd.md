# B5.1 dashboard selection tablet evidence

This open B5.1 slice aligns three dashboard selection and editing surfaces with
the shared `AppPageScaffold`, `SettingsSection` and `SettingsActionTile`
language. It does not close B5.1 or claim physical Huawei, DeX or TalkBack
acceptance.

## Acceptance

1. The single-entity picker uses a bounded tablet surface, localized search,
   lazy results and named 48 dp actions. Empty and filtered states stay
   distinct, and selecting a result returns the same Home Assistant entity.
2. The multi-entity picker exposes each row as one named, selectable action.
   Selection state is available to accessibility services, the Add action is
   disabled for an empty selection, and the result contains the selected
   entity IDs without dispatching a device command.
3. The dashboard card editor keeps its existing persistence and lifecycle
   authority while exposing 48 dp settings, size and movement controls. Drag
   handles receive localized names and save failures are announced as live
   status updates.

The widget matrix covers English and Turkish at 600 and 1200 logical pixels
with 200% text. It uses synthetic entities and repositories; no Home Assistant
or other home service is contacted. RED commit `5483727b` records the layout,
target-size and semantics gaps before the production changes.

## Verification

```text
flutter test \
  test/features/dashboard/entity_picker_screen_test.dart \
  test/features/dashboard/dashboard_edit_ui_test.dart

flutter test \
  test/features/dashboard/dashboard_accessibility_test.dart \
  test/features/dashboard/dashboard_tile_accessibility_test.dart \
  test/features/dashboard/dashboard_widget_picker_test.dart \
  test/features/dashboard/home_dashboard_test.dart \
  test/features/media/movie_night/movie_night_launcher_test.dart

flutter analyze \
  lib/features/dashboard/presentation/entity_picker_screen.dart \
  lib/features/dashboard/presentation/entity_multi_picker_screen.dart \
  lib/features/dashboard/presentation/dashboard_card_editor_screen.dart \
  test/features/dashboard/entity_picker_screen_test.dart \
  test/features/dashboard/dashboard_edit_ui_test.dart

python3 tool/check_security_policy.py
python3 tool/execution_queue.py validate
git diff --check
```

The focused suites pass **122/122** with no analyzer, queue, security-policy or
diff issues. Exact PR CI and a physical-device visual/accessibility pass remain
separate acceptance gates.
