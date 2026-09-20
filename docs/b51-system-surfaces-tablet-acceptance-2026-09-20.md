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

## Acceptance 2 — truthful state language

- Saved window-profile preference, current platform observation and supported
  device result remain separate. A saved request never claims the current
  system bars or window mode changed, and an unreadable observation is not
  rendered as a false value or a verified result.
- Ambient library and intercom station surfaces expose distinct loading, empty
  and error states. Errors use a bounded localized TalkBack live region and a
  fresh retry action; private platform/storage details never reach the UI.
- Selected window profiles expose selected button semantics; unavailable
  actions remain disabled instead of claiming success. Save failure keeps the
  previous saved choice active.

## Acceptance 3 — current authority and no stale callback

- Captured window, ambient preview and intercom actions expire when app
  interaction, route visibility or lifecycle authority is lost. Returning to
  the screen never revives an old callback.
- Window preference writes re-check current window interaction, route and
  lifecycle authority inside the shared serialized configuration writer before
  touching storage, and publish the new value only while the same authority is
  current.
- Ambient retry and preview, intercom retry/add/edit, and window refresh/save
  all fail closed when the owning route is no longer current.
- A retained intercom row cannot open a station removed or changed by the
  latest provider snapshot; a resumed window screen rebuilds fresh actions
  while callbacks captured before backgrounding remain retired.

- The intercom editor additionally binds each operation to the current direct
  Home Assistant home/source and connection snapshot. A changed home, account,
  session-owned interaction scope, route or lifecycle retires the operation;
  late callbacks do not start a write or navigation. These local panes never
  create or elevate Core, home, account or session authority themselves.

## Automated evidence

- `flutter test test/features/ambient/ambient_ui_test.dart test/features/intercom/intercom_screen_test.dart test/features/settings/window_panel_screen_test.dart`
- `flutter test test/features/settings/window_profile_test.dart`
- The combined focused run passes **58/58** tests, including loading/empty/error,
  toggle, stale station and lifecycle-return regressions.
- Targeted `flutter analyze` for the four production and four test files.
- `tool/check_commit_progress.py`, `tool/execution_queue.py`, `git diff --check`,
  `gitleaks`, and merge-tree checks against current open pull request heads.

No queue item is closed by this package; physical tablet and integration gates
remain unchanged.
