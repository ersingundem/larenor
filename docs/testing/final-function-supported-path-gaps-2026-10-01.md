# Supported production-path gaps — 1 October 2026

This independent read-only review is bound to source
`721952a00d8ac02c5e6b2ada71211a579b8eb768`. It compares explicit plan
requirements with actual production paths. Passing narrow tests and an honest
unsupported capability do not prove that a required software behavior exists.
These findings keep FINAL.FUNCTION open; no later FINAL has started.

## F18 and F27 power-hold composition

F18 explicitly protects downloads/jobs before database checkpoint and server
shutdown. Its heavy-work admission routes and active-work tables at this source
do not include normal F27 offline grants or transfers. Offline create/chunk/
progress use `/api/v1/media/offline/grants`, and durable grants can be
`granted`/`transferring`; F18 does not see either admission or ongoing provider
I/O. This is a supported software composition gap, not a physical UPS gate.

Required closure: hold and new grant/first-transfer admission share a database
transaction fence; already admitted transfers can finish or revoke; drain
sees actual durable transfers and in-flight I/O, and interruption/deadline
remains fail closed. Client CAS/integrity/authority and no-replay behavior stay
intact. Named normal Core concurrency and restart tests are required.

Sources: `server/larenor_server/power_recovery/service.py`,
`server/larenor_server/offline_media/service.py`, and
`docs/feature-expansion-plan-2026-09-05.md`. F18 is reworking.

## F60 normal Start sequence

The normal Flutter Start calls `stream` directly. Native `launch` separately
performs Sunshine launch and current-game readback. The real owned native test
launches first in both lifetimes, while the normal Core fixture masks the
omission by expecting only stream and stop.

Required closure: one captured-authority/session, durable one-use launch,
exact `native_observed/appRunning/currentGameMatched`, then a fresh stream
grant. Unknown/lost/late launch never sends stream, remains recoverable by
exact local close, and does not replay after restart or logout. Busy state
spans both commands. Sources: `game_stream_client_controller.dart`,
`MoonlightEmbeddedRuntime.kt`, `MoonlightOwnedSunshineStreamTest.kt`.
F60 remains reworking; its separate actual native CI is still required.

## F62 required basic behavior

The explicit remote-access plan includes basic keyboard/Turkish/IME/shortcuts,
display modes/fullscreen/DPI, pointer behavior, remote audio, and permissioned
microphone/file redirection. At this source:

- Physical keys outside a small mapping can terminate the session; persisted
  keyboard layout is not consumed; Unicode/IME is not implemented.
- Display-mode choices are persisted without rendering/request behavior;
  same-size density changes and fullscreen are not implemented.
- Absolute pointer support is incorrectly advertised as touchpad support;
  wheel and relative pointer behavior are absent.
- Remote audio, microphone, and SAF-scoped file redirection lack normal
  production paths. Their false/off reporting is honest but not completion.
- Unsupported RD Gateway fields/password are exposed before capability gating.

Required closure: actual source-locked runtime and usable normal UI for each
supported basic behavior, closed permissions and authority/lifecycle limits,
plus host-observed effects. Advanced RemoteApp/GFX/UDP/multimonitor depend on
explicit engine/host capability evidence; physical Huawei/DeX/Windows remains
MANUAL. Basic missing software is not moved into MANUAL. F62 remains reworking.

The first coherent repair is keyboard/layout/Unicode-IME/shortcuts and a
nonfatal unsupported-key boundary. Display/pointer, remote audio, microphone,
and SAF follow as separate testable slices within FINAL.FUNCTION.

Sources: `docs/remote-access-plan-2026-09-05.md:105`,
`rdp_session_panel.dart`, `rdp_session_controller.dart`, `rdp_engine.dart`,
`RdpNativeBridge.kt`, `RdpFreeRdpEngine.kt`, and `RdpPackagedRuntime.kt`.

## Other inspected entries

F55 actual Zigbee2MQTT OTA check/preview/confirm/readback and F44 actual Frigate
protected-WebP analysis have normal production wiring and named source/runtime
evidence. This review found no new supported software blocker in those entries;
physical radio/training/provider performance remains separately tracked.

Accepted counters remain35/127 tasks and3/63 selected features. F18 leaves
CI-waiting until the new composition closes:68 tasks/57 selected features
await CI; F18/F60/F62 rework and only FINAL.FUNCTION is active.

## Changed-source closure checkpoint

F18 shared offline admission/hold and durable/in-flight drain are implemented at `edffbc9a`; root9 focused tests passed. The independent NUT notification publication race is closed at `5ca1d212`; root28 passed/1 existing Linux-only skip, Ruff and review passed. F18 is now awaiting CI.

F60 normal verified launch→stream is implemented at `07a80382` (root11+1 Core TCP), and the actual packaged spinner ownership cycle is fixed at `b2eb56fa` (root48 native/0skip, AndroidTest compile). Strict exacta8 stream run36835162847 is still running; F60 remains reworking until actual native effects are accepted.

F62 basic keyboard/Turkish layout/Unicode negotiation is implemented at `413007f7` (root49 Flutter/analysis, author21 actual-AAR JVM). The other required display, pointer, audio/microphone/SAF and Gateway software gaps remain open. Exact03f run36831825081 failed initialFrameWait/connectionFailed; canonical1613B receipt verified, underlying provider cause unproved. F62 stays reworking.

Strict live-leaf PID proof at `a8dda895` passed root21 portable tests and the named actual Linux/CoreUID IPC cgroup run36835138089. This scoped result is distinct from the failed older721 broad F08 observer. Current totals:69 tasks/58 selected features awaiting CI; accepted35/127 and3/63 unchanged. Only FINAL.FUNCTION is active.
