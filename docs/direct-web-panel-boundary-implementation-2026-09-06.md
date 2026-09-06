# Direct dashboard web-panel ownership

This isolated Client slice starts at `c8ccb670e4025c57fb26c0d1f3856aa84b919269` and changes only the Direct dashboard `WebviewTile` wrapper. It is a source-ownership boundary for a saved Direct-home website, including a tile accidentally retained under a Core, pending or failed home source. It does not introduce a Core website adapter.

The wrapper captures its Direct owner for its lifetime, watches the current scope, and supplies that ownership check to the existing `WebPanelView` asynchronous setup and navigation guards. The captured owner must still match the current provider instance, including when a retained widget moves between separately live containers. Losing ownership hides the tile and permanently retires that wrapper. Returning to Direct requires a fresh wrapper/runtime. Existing URL policy, native renderer retirement, route/interaction/PIN rules and generic personal `WebPanelView` behavior remain in their existing owners.

The tile URL and website options belong to the Direct dashboard record. Native WebView cookies, local storage and cache remain device-shared browser-session data. This change neither copies Home Assistant API credentials into the website nor clears global browser data on a source switch. Existing already-dispatched native calls may settle and renderer retirement may disable JavaScript/load a blank page; the guarantee is no newly authorized saved-URL load or navigation after source loss, not rollback of native work or a network firewall.

## Runtime evidence

The tests use a real `HomeSessionController` and actual Direct-access provider with a fake native WebView platform. They do not open a browser, contact a website or access a home service. The existing standalone dashboard test harness now supplies `ProviderScope`, matching the wrapper's production provider dependency; its behavior assertions remain intact.

- RED `14b8b64`: 2 passed, 6 failed. Cold Core/pending/error constructed renderers, suspended native setup loaded the retained Direct URL, and a saved navigation callback accepted source loss. The current-Direct and explicitly personal generic-panel positive cases passed.
- RED log: `/private/tmp/larenor-webview-direct-red.log`.
- Minimal GREEN `25cf76c`: 8 new source-boundary cases plus 23 existing WebviewTile cases, 31 passed. Log: `/private/tmp/larenor-webview-direct-green.log`.
- Scope-reparent RED `6e7f3a0`: 8 passed, 1 failed. The old Direct container was kept alive with an explicit subscription while the same keyed widget moved to a separate Core container; the retained panel stayed present. Log: `/private/tmp/larenor-webview-direct-reparent-verified.log`. The preceding exploratory run had an invalid subscription-teardown fixture and is not counted as runtime RED evidence.
- Final behavioral GREEN `1df92bd23bc535a617aa6c71a00a2afccfe63eef`: all 32 focused cases passed, including permanent retirement when moving back to the old Direct container. Log: `/private/tmp/larenor-webview-direct-reparent-green.log`.

After formatting, the complete related WebPanel suite plus existing WebviewTile tests passed: **79 tests** in `/private/tmp/larenor-webview-direct-final-green.log`. This includes generic personal rendering, URL/options persistence, origin rules, permission denial, deadlines, native lifecycle, and PIN/explicit-confirmation requirements for global data deletion. Three owned Dart files analyzed with **0 issues** (`/private/tmp/larenor-webview-direct-final-analyze.log`); formatting covered those three files and changed only the two tests (`/private/tmp/larenor-webview-direct-format.log`). `git diff --check` was clean.

Line coverage from this related run is **19/19 (100%)** for the changed wrapper, **186/200 (93.0%)** for the unchanged generic panel, and **58/63 (92.1%)** for its unchanged data coordinator. This is LCOV line coverage, not a branch-coverage claim. Evidence: `/private/tmp/larenor-webview-direct-final-coverage.info`.

All Flutter/Dart commands used `/private/tmp/larenor-flutter-check.py` to serialize access to the shared SDK. The regression command was `flutter test --coverage test/features/web_panel test/features/dashboard/webview_tile_test.dart --reporter expanded` through that wrapper. Root independently reviewed behavioral source `1df92bd` and found no open P1/P2 issue in this scope.

No Android emulator, physical tablet, real website or native browser-session isolation acceptance is claimed by these fake-platform tests. This is a subsequent package; it is not evidence for the independently running `ad5f866` release. No main branch publication, shared inventory edit or global browser-data policy change was performed here.
