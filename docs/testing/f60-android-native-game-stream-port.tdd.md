# F60 Android native game-stream port — TDD acceptance

This slice places a bounded Android `MethodChannel` adapter under the F60
Client session contract. It deliberately ships without a Moonlight/Sunshine
runtime: capabilities report `unavailable`, and every command fails closed as
`engineUnavailable`. No physical codec, input, network wake, or stream playback
acceptance is claimed.

## Acceptance matrix

| Criterion | Production boundary | Automated evidence |
| --- | --- | --- |
| Opaque credential handle | Flutter and Kotlin accept one 32-hex handle, redact public string output, reject unknown credential fields, and never accept a raw token/password field. The native engine interface receives only that opaque identifier. | `android_game_stream_port_test.dart`: bind payload/redaction and identity tests. `GameStreamNativeAdapterTest`: strict handle/parser tests. |
| Lifecycle, route, and epoch cancellation | Binding is exact for session, epoch, and account/route/lifecycle/idle/interaction revisions. Flutter revokes locally before awaiting native retirement. Android activity pause, focus loss, replacement binding, retire, and disposal invalidate the generation; a late callback cannot become success. | Flutter late-callback/rebind tests and Kotlin retirement/late-completion tests. |
| Bounded Moonlight/Sunshine command/result bridge | Only `wake`, `launch`, `stream`, and `stop` are accepted, with at most one native in-flight effect per intent and one engine dispatch for an identical replay. Receipt IDs, intent, all seven source revisions, state, and readback revision must match. Missing runtime and ambiguous failures remain terminal and are never auto-replayed. | Flutter capability/receipt tests and Kotlin unavailable, duplicate, mismatch, and bounded-intent tests. |

## Verification

- `flutter test test/features/game_streaming/android_game_stream_port_test.dart test/features/game_streaming/game_stream_session_test.dart`
- `/Users/ersingundem/oikos/android/gradlew -p android :app:testDebugUnitTest --tests 'com.ersingundem.larenor.game.*'`
- Targeted Flutter analysis plus repository security, queue, progress, leak, and diff checks are recorded with the final wrapper commit.

## Deferred physical acceptance

A later package must supply and license a reviewed native streaming engine,
resolve opaque handles from Android-owned secure storage, and prove Moonlight /
Sunshine pairing, video/audio decode, controller/keyboard input, wake-on-LAN,
display attach/detach, and real tablet/DeX behavior. This contract cannot be used
as evidence for those device-level outcomes.
