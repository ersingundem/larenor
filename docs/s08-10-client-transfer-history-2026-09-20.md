# S08.10 Client transfer receipt history

20 September 2026. This slice adds the retained bounded-transfer receipt view
to the Android tablet Client. It does not close S08.10: packaged product
providers, upload/media protocols, and physical SAF acceptance remain open.

## User journey and guarantees

An authorized home member can open a resource's transfer history and distinguish
an accepted, completed, or interrupted Core result. The Client sends only a
bounded `GET` for the selected Core/home/resource tuple. It accepts at most 50
content-free receipts, validates every identifier, digest, media type, service
revision, timestamp, and the Server's creation-time ordering, and caps the JSON
body at 64 KiB.

The controller binds the visible history to the current session and exact
resource authority. Sign-out, window retirement, account replacement, or loss
of the resource/ACL view closes the transport and clears retained rows. A stale
callback cannot publish into a later screen epoch. The EN/TR tablet surface uses
48 dp actions, keyboard/TalkBack button semantics, live loading/error status,
and wrapping receipt text at 600 and 1200 logical pixels with 2x text.

## TDD evidence

| Guarantee | Evidence | Result |
| --- | --- | --- |
| Missing API/model/lifecycle behavior was exercised before implementation | `7a654f2a`; focused tests failed at compile time on the intended missing symbols | RED |
| Missing localized tablet action and receipt presentation was exercised before implementation | `9c192d7f`; real-font tablet test failed on the intended missing localization/UI contract | RED |
| Binary transfer and receipt history remain fail-closed | `flutter test test/features/home_resources/bounded_download_test.dart test/features/home_resources/core_bounded_download_controller_test.dart` | PASS |
| EN/TR, light/dark, 600/1200 px, 2x text tablet journey renders and operates | `flutter test test/features/home_resources/home_resources_tablet_test.dart` | PASS |
| Owned Client source and tests are statically clean | `flutter analyze --no-pub lib/features/home_resources test/features/home_resources` | PASS |

The combined focused run completed with **31 PASS** and zero skips. The branch
still requires repository CI and review before this evidence is merged.
