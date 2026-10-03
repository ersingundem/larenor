# F60 owned OSC gamepad prepare ordering (2026-10-03)

Exact run `37142746206` reached the owned input phase after the XI2 touch effect, then failed at host `gamepadArm` before Android received `gamepad_armed`. The bounded receipt classified the inner host error as `unclassified`; it did not prove a kernel, ACL, or device-identity cause.

The pinned production paths establish an independent ordering defect. Moonlight's onscreen controller writes through `ControllerHandler.defaultContext`. That context inherits the no-op `GenericControllerContext.sendControllerArrival()`, so enabling OSC and advertising an attached gamepad mask does not emit a controller-arrival packet. Its first network controller packet is emitted by `reportOscState()` after a visible OSC control changes. Pinned Sunshine allocates a virtual gamepad only on a controller-arrival packet or the first active multi-controller packet. The old fixture asked the host to discover/open the evdev node before dispatching the first OSC event, so that node could not yet exist.

The first repair used the A button both for preparation and for the post-arm witness. That did not establish a causal boundary: Moonlight input and the private TCP phase channel are distinct transports, so a complete preparation A packet could arrive after the host's evdev drain and satisfy the BTN_SOUTH witness before the second A effect.

The corrected fixture uses the actual visible default-layout B button once before `gamepad_ready`. The scoped preference fixture requires `onlyL3R3=false` and `flipFaceButtons=false`; the pinned Moonlight layout places A at element 1 and B at element 2, with A_FLAG and B_FLAG respectively. Pinned Sunshine's standard virtual controller maps A to BTN_SOUTH and B to BTN_EAST. The B transition creates the virtual controller without a BTN_SOUTH press. The host then discovers the exact newly owned node, grants, opens, and drains it before sending `gamepad_armed`. A delayed full-state B report may carry an idle BTN_SOUTH=0; the witness ignores only that pre-press idle value. It still requires the post-arm A's exact BTN_SOUTH down + SYN_REPORT + BTN_SOUTH up + SYN_REPORT. Unexpected BTN_SOUTH transitions after a down, SYN_DROPPED, missing commits, and missing A remain fail-closed.

The private phase stream accepts only canonical three-key messages with the exact 64-lowerhex run nonce and the expected next phase. A single accepted loopback stream and exact `gamepad_ready -> gamepad_armed -> gamepad_sent -> gamepad_observed` sequence reject wrong nonce, omission, reorder, and replay. The nonce is the per-run epoch binding; there is no separately published epoch field.

A zero-candidate discovery deadline yields only the fixed public category `gamepadDiscoveryTimeout`, valid only at exact phase `gamepadArm`. Ambiguous, ACL, identity, and other failures remain `unclassified` or closed contract/I/O failures; no device name, path, event data, provider text, or nonce is published.

Portable RED evidence uses the new regressions against the superseded A/A candidate: distinct pre-arm B ordering is absent and a delayed full-state B report is rejected before the later A can be witnessed. The corrected candidate passes 24/24 owned-gamepad tests and 77/77 stream-runner tests, with zero failures, errors, or skips; Python compile checks pass. These checks establish source ordering and host witness semantics only. No Gradle, emulator, hosted runner, virtual-controller creation, or actual evdev effect was executed. Changed-source hosted acceptance remains required.

## Root integrated-source verification

Root verified the six frozen base/candidate hashes and all bounded evidence hashes, plus three pinned primary-source copies. Independent second review found no P1/P2: visible B cannot satisfy the required BTN_SOUTH press even when its transport arrives after host drain; missing/interleaved A stays fail-closed. Shared source differs from the freeze only by removing one unused test import.

Root passed 111 portable runner/gamepad/workflow tests and scoped Ruff. Actual Java17/SDK native5 composition compiled the changed instrumentation source with required product engines: 278 tasks, 30 executed, 248 up-to-date. Every tracked Kotlin/Java source byte matched the shared checkout. The first compile attempt failed due to no disk space while copying generated Flutter assets; root removed only this task's generated Flutter cache, then the same scoped build completed successfully.

- `larenor-root-f60-preparation-v2-20261003.log`: SHA-256 `21f27a2906a0c7951db59cdbb54583f6408620d8ecb5819d7781ee9dd1b6a688`.
- `larenor-root-f60-preparation-v2-android-compile-20261003.log`: SHA-256 `9344e16ad9a14c51d13e7cad2771df1c71283a7f57b4367f8acf6ddff9f77da3`.
- `larenor-root-f60-preparation-v2-android-compile-retry-20261003.log`: SHA-256 `622eacf686e65978a29e83a904c49ca9e31cae27446d2ad89db7c42655280c64`.

Frozen source manifest SHA-256 `aa7d872cd4ab2af56cc180af9af60c546cce8773fb95892225b7d963121e6fa8`; review SHA-256 `b4680a66dcdcc927568fb811ad8c3665af1be24045114463ea41276a7b80f33a`. This proves scoped source and compilation only. Virtual controller creation, actual evdev gamepad effect, two stream lifetimes and strict closure still require changed-source hosted acceptance. Feature acceptance/dependencies, main merge and other final stages remain open.
