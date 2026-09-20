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

## Acceptance 2 — authority survives no stale callback

- Captured window, ambient preview and intercom actions expire when app
  interaction, route visibility or lifecycle authority is lost. Returning to
  the screen never revives an old callback.
- Window preference writes re-check the captured authority inside the shared
  serialized configuration writer before touching storage, and publish the new
  value only while the same authority is current.
- Ambient retry and preview, intercom retry/add/edit, and window refresh/save
  all fail closed when the owning route is no longer current.

## Acceptance 3 — state is accessible and truthful

- Selected window profiles expose selected button semantics; unavailable
  actions remain disabled instead of claiming success.
- Save failure is a TalkBack live region and never includes storage internals.
- Loading, retry and regular actions keep the same card geometry across the
  three surfaces; keyboard, TalkBack and 200% text tests use localized labels.

## Automated evidence

- `flutter test test/features/ambient/ambient_ui_test.dart test/features/intercom/intercom_screen_test.dart test/features/settings/window_panel_screen_test.dart`
- `flutter test test/features/settings/window_profile_test.dart`
- Targeted `flutter analyze` for the four production and four test files.
- `tool/check_commit_progress.py`, `tool/execution_queue.py`, `git diff --check`,
  `gitleaks`, and merge-tree checks against current open pull request heads.

No queue item is closed by this package; physical tablet and integration gates
remain unchanged.
