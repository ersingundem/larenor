# F52 dual-display software acceptance — 2026-09-30

## Shipped boundary

- The primary Flutter engine reads a versioned, authenticated Core authority and public Core-health snapshot immediately before and after the Android presentation call. The response binds the exact Core, home, account, account revision, home-resource registry revision, session family, and packaged public-route policy. Core rechecks that authority after reading the host metrics.
- The Android bridge refreshes `DisplayManager` at the presentation boundary. Add, size/density change, and removal events replace the topology revision and per-display generation. A stale request cannot attach to a reconnected display with the same numeric display ID.
- The secondary engine is plugin-free and receives only `core.status` plus a closed v1 snapshot containing service/API state, normalized one-minute host load, Core-process RSS, Core data-volume capacity, process uptime, observation time, and a maximum 15-second freshness lifetime. It receives no access token, Core/home/account/session identity, hostname/path, provider response, media metadata, floor-plan data, or player handle.
- The primary refreshes this snapshot every five seconds through the exact active display session. Read failure, authority drift, malformed native receipt, lifecycle loss, or topology change dismisses the presentation. The isolated engine independently hides the values after 15 seconds, including when the primary process disappears.
- Media, calendar, weather, floor-plan, and playback tasks are not advertised. The public snapshot is actual local Core/host observation; unavailable OS metrics fail the read with `server_unavailable` instead of using zero or canned values.
- A floor-plan secondary surface is optional and is not advertised by this contract.

## Primary contracts

- [Flutter: Multiple Flutter screens or views](https://docs.flutter.dev/add-to-app/multiple-flutters) documents independent engine navigation and application state, and platform-channel communication between instances. `FlutterEngineGroup` is the preferred resource-sharing optimization; this implementation uses a separately constructed engine to preserve the already-shipped isolation boundary.
- [Android `Display`](https://developer.android.com/reference/android/view/Display) defines `FLAG_PRESENTATION` as a suitable secondary presentation display and distinguishes `FLAG_SECURE`. Larenor advertises only `FLAG_PRESENTATION` displays and still forbids private secondary routes regardless of the secure flag.
- [Android `DisplayManager.DisplayListener`](https://developer.android.com/reference/android/hardware/display/DisplayManager.DisplayListener) defines add, changed, and removed callbacks; changed includes size and density changes. Larenor turns each observed signature change into a new display generation.
- [Android multi-window support](https://developer.android.com/develop/ui/views/layout/support-multi-window-mode) requires handling configuration changes and freely resizable desktop windows. The primary activity already forwards configuration changes; the display topology test exercises logical display resize separately.

## Evidence

```text
uv run --project server pytest -q server/tests/test_f52_multi_display_authority.py
4 passed

flutter test --no-pub \
  test/features/multi_display
24 passed; 1 explicit normal-Core runner skip

flutter analyze lib/features/multi_display test/features/multi_display
No issues found

uv run --project server python server/tests/support/f52_flutter_acceptance.py
success phase: 1 passed, including a later five-second refresh
revoked-during-presentation phase: 1 passed

cd android && ./gradlew :app:testDebugUnitTest \
  --tests com.ersingundem.larenor.display.AndroidDualDisplayHostTest \
  --tests com.ersingundem.larenor.display.DualDisplayContractTest
5 passed; BUILD SUCCESSFUL
```

The normal-Core gate runs the production Flutter HTTP client against a normal installed Core TCP listener. It verifies actual bounded host metrics, successful pre/post authority reads, a later refresh, and a revoked-session race where the native boundary returns but the postflight read fails and the presentation is dismissed. The Android gate uses the real `DisplayManager`/`VirtualDisplay` implementation under Robolectric to add, resize, and remove a logical external display; contract tests cover the closed public payload, monotonic updates, exact session receipt, focus/lifecycle retirement, duplicate intent, forbidden routes, and reattachment generation. Robolectric does not project a hardware display's `FLAG_PRESENTATION`, so this test injects only the eligibility predicate while retaining the production manager, listener, metrics, and topology code; the production predicate remains the exact platform flag check.

## Open physical evidence

Physical Samsung DeX/manual external-display evidence remains open. A device run must cover dock attach/detach, orientation changes, repeated desktop-window resizing, focus changes, playback continuing under the primary owner, and visual confirmation that private content never appears externally. The software gates above do not claim that hardware acceptance.
