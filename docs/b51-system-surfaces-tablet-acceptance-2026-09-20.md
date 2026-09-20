# B5.1 system surfaces tablet acceptance

Status: software acceptance complete; queue progress remains **17/125** and
feature progress remains **0/63**.

## Acceptance 1 — one tablet settings language

- Window mode, ambient display and intercom setup use the shared Cupertino
  settings section and action row components.
- Every primary action exposes one button semantics node with a target of at
  least 48 dp and native Enter activation.
- EN/TR widget matrices cover 600 and 1200 logical pixel widths at 200% text;
  compact and wide DeX resize coverage remains scrollable without overflow.
- Ambient switches expose named 60 by 48 dp toggle targets and support native
  Enter/Space activation without merging unrelated hint text into the action.

## Acceptance 2 — authority survives no stale callback

- Captured window, ambient preview and intercom actions expire when app
  interaction, route visibility or lifecycle authority is lost. Returning to
  the screen never revives an old callback.
- Window preference writes re-check the captured authority inside the shared
  serialized configuration writer before touching storage, and publish the new
  value only while the same authority is current.
- Ambient retry and preview, intercom retry/add/edit, and window refresh/save
  all fail closed when the owning route is no longer current.
- A retained intercom row cannot open a station removed or changed by the
  latest provider snapshot; a resumed window screen rebuilds fresh actions
  while callbacks captured before backgrounding remain retired.

## Acceptance 3 — state is accessible and truthful

- Selected window profiles expose selected button semantics; unavailable
  actions remain disabled instead of claiming success.
- Save failure is a TalkBack live region and never includes storage internals.
- Loading, retry and regular actions keep the same card geometry across the
  three surfaces; keyboard, TalkBack and 200% text tests use localized labels.

## Automated evidence

- `flutter test test/features/ambient/ambient_ui_test.dart test/features/intercom/intercom_screen_test.dart test/features/settings/window_panel_screen_test.dart`
- `flutter test test/features/settings/window_profile_test.dart`
- The combined focused run passes **55/55** tests, including the new toggle,
  stale station and lifecycle-return regressions.
- Targeted `flutter analyze` for the four production and four test files.
- `tool/check_commit_progress.py`, `tool/execution_queue.py`, `git diff --check`,
  `gitleaks`, and merge-tree checks against current open pull request heads.

No queue item is closed by this package; physical tablet and integration gates
remain unchanged.
