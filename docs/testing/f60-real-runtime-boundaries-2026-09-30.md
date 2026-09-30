# F60 real runtime boundaries — 30 September 2026

F60 is **reworking**. The existing native provider opens the separately installed Moonlight application; it does not embed a streaming engine or expose successful `stream`/input receipts. Core host records alone do not establish host pairing or playback. An external app being installed must not be presented as a reviewed Larenor engine or a verified paired host.

## Verified upstream integration surface

The official [Moonlight Android manifest](https://github.com/moonlight-stream/moonlight-android/blob/master/app/src/main/AndroidManifest.xml) exports its PC selector and shortcut trampoline; its stream activity is not a general exported playback API. The official [shortcut implementation](https://github.com/moonlight-stream/moonlight-android/blob/master/app/src/main/java/com/limelight/ShortcutTrampoline.java) looks up an existing computer UUID or name in Moonlight's private database and optionally resolves an application. This is not an authenticated Larenor pairing or stream-result contract. Sunshine's [official API](https://docs.lizardbyte.dev/projects/sunshine/master/md_docs_2api.html?lng=en) handles a PIN for an actual pending pairing session; creating an arbitrary Core record is not that operation. A functioning reviewed adapter still needs actual pairing, video/audio/input and disconnect acceptance against an owned host. Physical GPU/codec/device measurements remain distinct.

## Current UI correction

The settings route now says that Moonlight is installed and pairing/playback take place in that app. Handoff availability uses informational blue rather than engine-accepted green, and Core metadata uses an information icon rather than a verified-pairing shield. The personal-session retirement statement is shown only for a real managed engine; the handoff route explicitly names Moonlight's lifecycle ownership.

Opening another app normally pauses Larenor before a method-channel reply arrives. Retirement now clears the old launch-busy flag; after returning and explicitly refreshing, a new launch is possible. A late reply from the old generation cannot clear or alter a newer pending launch. The current gate is checked immediately before external-app dispatch, including a tap from a stale rendered button.

These are real usability/lifecycle fixes. They do not close F60's missing Client host registration/pairing and native playback/input integration. Queue acceptance and the `reworking` label remain unchanged.

## Focused evidence

Root ran `flutter test --no-pub test/features/game_streaming/game_stream_settings_screen_test.dart`: 9 passed, zero skipped. Scoped `flutter analyze --no-pub` over the route and its tests was clean. The new regressions exercise retirement/reentry, an old reply while a successor launch is pending, and a stale already-rendered tap in TR. Existing EN/TR 600/1280 layouts and keyboard/accessibility checks remain covered. These widget tests use a controlled port and prove UI/ownership only; no external Moonlight or Sunshine interoperability is claimed.

The first newly added lifecycle regression missed its refresh tap under the pinned navigation bar after a 2×-text layout change. That fixture run failed and is not acceptance evidence. The test now returns the real scroll view to its minimum extent before tapping; the final root rerun above completed all 9 tests without hit-test warnings. This correction supersedes the premature 9-pass note in the preceding documentation commit.
