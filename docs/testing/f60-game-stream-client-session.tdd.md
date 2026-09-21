# F60 tablet game-stream Client session contract

This first Client-only slice defines the authority and native-port boundary for
streaming a home PC game to the Android tablet or a selected attached display.
It does not embed or claim a Moonlight/Sunshine engine.

| Acceptance | Software evidence |
| --- | --- |
| Exact stream snapshots | A session is created only from current host, pairing, app, display, codec, network, and policy revisions. The app must belong to the host revision, the codec and resolution must be allowed, the display must remain attached, and the network must be local and policy-compatible. Unsupported or changed snapshots fail before the native port is called. |
| PIN, route, lifecycle and idle ownership | The memory-only lease is exact to account owner identity plus account, PIN, route, lifecycle, idle, and interaction revisions. Foreground, visible route, active interaction, PIN, idle duration, and maximum session lifetime are rechecked before every effect and after every callback. Detach, authority loss, expiry, resolver failure, or explicit close retires the lease one way, completes pending work as `unknown`, and blocks late callbacks from reviving it. |
| Secret-free idempotent intents | Pairing keys and tokens are outside the public state and command models; the native port receives only an opaque credential handle. Wake, launch, stream, and stop are ordered, single-flight and idempotent per session. Only an exact command/revision readback advances state. Lost, malformed, mismatched, ambiguous, or late acknowledgements remain `unknown`; they are never replayed automatically. |

`game_stream_session_test.dart` covers all revision fences, current and stale
PIN/route/lifecycle/idle authority, session expiry, ordered intent readback,
concurrent duplicates, lost acknowledgement, detach, late callbacks, and
secret-free diagnostics.

F60 remains open for the reviewed native Moonlight/Sunshine adapter and
licensing/package decision, encrypted pairing storage, discovery/pairing UI,
video/audio/input surfaces, gamepad/touch/latency handling, Client-to-isolated
host E2E, exact-commit CI, and separate physical tablet/DeX/host/GPU/codec
acceptance. Queue progress remains at the inherited **20/125** and selected
feature progress remains **0/63**.
