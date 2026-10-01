# F60 owned Sunshine Android stream gate

## Scope

This gate is the first F60 acceptance surface designed to exercise a packaged
Android client against a real, pinned Sunshine process. It is separate from the
host-readiness and production-NSD gates. Those earlier gates remain useful and
do not imply pairing or streaming.

The workflow is restricted to GitHub-hosted Ubuntu 24.04 x86_64 runners. It
installs Sunshine `v2026.914.233613` from the exact reviewed release asset and
SHA-256 already enforced by `tool/f60_sunshine_owned_host.py`. It builds the
pinned Moonlight Android source at
`b48494cb96bff23d8886c4775cc4f39a1075495d` into a receipted AAR before the
instrumentation process starts.

The debug APK and Android-test APK are assembled before Sunshine, the PIN
bridge, the audio monitor, or the XI2 monitor starts. Their 300-second provider
deadlines therefore cover only the connected provider test, not an initial
Gradle compilation that is independently bounded to 1,200 seconds.

## Required causal sequence

One exact Android test must complete, without skips:

1. Production Android NSD discovers the owned `_nvstream._tcp` service.
2. The production Moonlight pairing implementation creates a cryptographic
   pairing request. A test-only PIN presenter sends the generated PIN once over
   an `adb reverse` loopback socket. The host accepts one canonical, nonce-bound
   message and approves only the exact pending `roth` client through Sunshine's
   pinned TLS API.
3. The client reads and commits the real NvHTTP app catalog, then launches the
   owned Desktop entry and obtains the current-game readback.
4. The client starts the real stream. A changing X11 clock is captured from the
   private Xvfb display by Sunshine's software H.264 encoder.
5. After Sunshine creates its private stereo sink, the host sends a generated
   48 kHz stereo tone to that exact sink. Android requires an actual MediaCodec
   rendered-frame callback and a complete positive `AudioTrack.write` callback
   for the exact bound session.
6. Android sends one A-key press/release through the production game activity.
   A private XI2 listener on the owned Xvfb display must observe the exact
   software key event pair.
7. A separate nonce-bound phase channel tells the host to arm an XI2 pointer
   listener before Android dispatches a real production touch down/move/up and
   relative mouse motion/button sequence. Acceptance requires two distinct
   X11 pointer positions plus an exact primary-button press/release pair.
8. Android taps the actual scoped Moonlight on-screen A button only after the
   host arms its exact newly owned Xbox Series evdev node. The host requires
   real `BTN_SOUTH` down/sync/up/sync before acknowledging this step. ACL
   grants and restoration require descriptor-bound effective-permission
   readback; `SYN_DROPPED` invalidates the observation.
9. Deliberate stop of the first lifetime succeeds only after the production
   connection reports that `NvConnection.stop()` returned. Native retires that
   exact session and creates a fresh second session, which must independently
   reach connection-started, rendered-frame, and full-PCM-write evidence.
10. Immediately before forced disconnect, the host verifies the exact private
   Sunshine client UUID captured after pairing is still present and enabled;
   a same-name replacement cannot satisfy this check. It then stops only the
   exact registered owned Sunshine process group. Android accepts only the
   exact second lease's real `connectionTerminated` callback, retires that
   session, locally clears its binding, and proves the command was never
   redispatched.

An API success response, a delay, a process exit, or a connection-start callback
alone is insufficient for output acceptance.

## Private control boundary

The PIN channel carries one JSON line of at most 256 bytes with exact keys
`nonce`, `pin`, and `schemaVersion`. The listener binds an ephemeral
`127.0.0.1` port. Android connects to fixed loopback port `49361`, mapped for
the duration of the test with `adb reverse`. The nonce is a one-run 256-bit
value. The bridge closes after its first message.

A distinct `adb reverse` connection maps Android loopback port `49362` to an
ephemeral host-only listener. It carries at most 512 bytes per canonical ASCII
JSON line, uses the same one-run nonce, and accepts only the fixed ordered phase
sequence `touch_ready`, `touch_sent`, `gamepad_ready`, `gamepad_sent`, and
`disconnect_ready`. Host replies are limited to `touch_armed`,
`touch_observed`, `gamepad_armed`, `gamepad_observed`, and
`owned_sunshine_stopped`. Coordinates, process identifiers, and the paired
client UUID remain process-private.

The host does not acknowledge `touch_armed` merely because `xinput` started.
The pinned `test-xi2` implementation prints its device list before it calls
`XISelectEvents` and `XSync`, so that listing is not a readiness signal. The
host sends a bounded owned X11 pointer-warp probe and acknowledges the phase only
after the same byte-bounded XI2 listener observes that exact root coordinate.
Probe events are cleared before Android input evidence is collected. Every XI2
`EVENT` header, including unknown event kinds, resets the current parser state;
truncated relevant events fail closed.

The stream-only Sunshine profile enables controller input and fixes the
emulated profile to `xseries`; readiness profiles keep controller input
disabled. Before any provider deadline, a hosted-runner-only preflight verifies
the exact `/dev/uhid` character-device/sysfs identity, loading only the fixed
`uhid` module when absent. After both APKs are prebuilt, a private ACL scope
opens that exact character device with `O_PATH|O_NOFOLLOW`, validates its
device/inode/rdev tuple, and retains the descriptor for the whole lease. The
initial ACL must contain only the base owner, group, and other entries; any
pre-existing named user/group or mask fails closed. ACL changes and restoration
address only `/proc/<owned-process>/fd/<descriptor>`, so replacement of the
device pathname cannot redirect them. The current runner UID receives `rw` and
the explicit ACL mask is the union of that permission and the unchanged base
group permission. A descriptor-bound `getfacl` readback must prove the named
entry, mask, unchanged base entries, and effective `rw` before the host opens
the node. It records every existing evdev identity before Sunshine starts.

At `gamepad_ready`, the host requires exactly one new, unsymlinked evdev whose
sysfs device number matches its `st_rdev` and whose name, vendor/product, unique
identity, and physical-path prefix match the pinned Sunshine Xbox Series
profile. Only that node receives a temporary current-UID read ACL. The host
uses the same descriptor-anchored, base-only ACL validation and mask/readback
proof before the host opens it read-only with `O_NOFOLLOW`. Pre-arm reports are
drained before `gamepad_armed`. `gamepad_observed` requires an actual evdev
`BTN_SOUTH` down report committed by `SYN_REPORT`, followed by `BTN_SOUTH` up
and its own `SYN_REPORT`; any `SYN_DROPPED` invalidates the evidence. Native
packet submission alone is insufficient. No `EVIOCGRAB`, global input-node
permission, group mutation, or mode `0666` is used. Both ACLs are restored from
their private in-memory snapshots through the retained descriptors on success,
cancellation, and failure. Restoration is read back, retried a bounded two
times on transient failure, and the snapshot plus descriptor remain retained
if both attempts fail.

The PIN is never written to a file, command argument, environment value, log,
JUnit report, public receipt, or artifact. Sunshine credentials, provider
addresses, TLS material, native binding identifiers, upstream app identifiers,
frames, and PCM bytes are also excluded from artifacts.

## Public receipt

The workflow may publish a receipt only after the exact named JUnit case passes,
the PIN bridge observes the paired client, the owned tone injector succeeds,
XI2 observes the key and pointer/button effects, evdev observes the on-screen
A-button effect, both stream lifetimes produce
their required output, the exact owned Sunshine process stops, the second
lifetime reports a real remote termination without redispatch, and Native
locally retires the binding. The UUID itself never enters the receipt. The receipt binds the
repository revision and Moonlight package hashes and exposes only bounded
proof booleans.

`streamAccepted: true` means only the named
`twoStreamOscInputDisconnectAndLocalRetirement` scope: real pairing, catalog,
launch, two independent frame/PCM lifetimes, software key and mouse effects,
the Moonlight on-screen-controller A-button effect, graceful stop,
provider-process disconnect, zero redispatch, and local binding
retirement. The same receipt says
`featureAccepted: false`, `localBindingCleared: true`,
`providerPairingRemoved: false`, and records provider pairing removal as
`unaccepted` as an out-of-scope/manual provider-admin boundary, not as a missing required tablet-removal feature. Source implementation and local unit tests are not streaming
acceptance, and this partial scope does not complete F60 functional acceptance.

## Current unpair compatibility boundary

The supported product promise is tablet-only removal with `local_cleared|unknown`, as the Client explicitly explains. Automatic Sunshine administrator pairing deletion is an optional separate capability; it is not a mandatory F60 acceptance step. The partial stream gate still cannot close external controller hardware, rumble, game consumption, physical input latency, or broad commit CI acceptance.

The pinned Moonlight client implements `NvHTTP.unpair()` as an unauthenticated
GameStream `GET /unpair`. The pinned Sunshine `nvhttp.cpp` does not register
that route. Sunshine's supported removal surface is the authenticated
configuration API `POST /api/clients/unpair`. The host harness does not call
that administrative route on behalf of Android and does not describe local
registration retirement as provider revocation. The owned provider state is
discarded when the private process workspace is removed after the test; that
test cleanup is not production revocation evidence.

Sunshine's configuration API calls `proc::proc.terminate()` after the last
client is removed. In the pinned source that object is the launched application
manager, not the Sunshine host. The configuration and GameStream servers remain
alive. This gate performs no administrative removal. It proves the paired
client remains present immediately before the owned provider is stopped; the
temporal readback is not a post-disconnect provider-removal claim.

## Limits

The visual proof is an actual MediaCodec rendered-frame callback, not a pixel
comparison or a quality judgment. The audio proof is an accepted complete PCM
write, not physical audibility. The key witness is software input delivered to
the owned X11 server; it does not prove a physical keyboard. Physical display,
speaker, physical mouse/touchscreen, external USB/Bluetooth controller, rumble,
game consumption, Wi-Fi, latency, HDR, HEVC,
AV1, DRM, and household-host
behavior remain manual or separately named acceptance work.

The Android emulator must reach Sunshine's real stream ports after production
NSD. There is no endpoint injection or `10.0.2.2` fallback. If the reviewed
emulator networking cannot carry the real stream, the gate fails rather than
substituting a fake transport.

The first production-NSD run `36792376426` did not reach the Python runner or
Sunshine. Its private job log records that the emulator was launched with
`-accel off` after its KVM probe found the runner user lacked permission for
`/dev/kvm`; Android Emulator `37.1.11.0` then remained ADB-offline until the
boot deadline. This is evidence of a hosted-emulator acceleration precondition
failure, not a Sunshine or production-NSD failure.

Both NSD and stream workflows now require `/dev/kvm` to be a character device,
apply the reviewed GitHub-hosted-runner mode `0666`, require read and write
access, and set `disable-linux-hw-accel: false`. A missing or inaccessible
device fails before emulator startup; there is no `-accel off` fallback. They
also retain the supported `-gpu swiftshader` renderer. Android's official
emulator documentation marks `swiftshader_indirect` deprecated since 36.4.9,
but that renderer correction was not the demonstrated cause of run
`36792376426`. A changed-source hosted run is still required; neither the
timeout nor these local workflow tests are provider evidence.

The changed-source discovery run `36796250482` and stream run `36796253857`
at exact revision `0036260b9d6eb09336b881889e885328f63d6520` both passed the
receipted Moonlight build and hosted KVM preflight, then failed before creating
the private provider workspace. Their fixed diagnostic was
`ModuleNotFoundError` for the public `tool` module: direct script execution put
`tool/`, rather than the checkout root, on Python's import path. Both workflows
now invoke the entrypoints as repository modules with `python3 -B -m`. Those
runs reached neither Sunshine, production NSD, Android instrumentation, nor a
receipt and provide no feature-acceptance evidence. A new changed-source run is
required.

## Primary protocol sources

- Sunshine pairing and launch server:
  <https://github.com/LizardByte/Sunshine/blob/v2026.914.233613/src/nvhttp.cpp>
- Sunshine Linux PulseAudio sink implementation:
  <https://github.com/LizardByte/Sunshine/blob/v2026.914.233613/src/platform/linux/audio.cpp>
- Sunshine mouse/button input gates and forwarding:
  <https://github.com/LizardByte/Sunshine/blob/v2026.914.233613/src/input.cpp>
- Sunshine controller and gamepad configuration:
  <https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html#controller>
- Linux kernel UHID userspace transport contract:
  <https://docs.kernel.org/hid/uhid.html>
- Linux kernel input event and synchronization contract:
  <https://docs.kernel.org/input/event-codes.html>
- Sunshine launched-application and process-group lifecycle:
  <https://github.com/LizardByte/Sunshine/blob/v2026.914.233613/src/process.cpp>
- Pinned xinput 1.6.4 XI2 subscription order:
  <https://gitlab.freedesktop.org/xorg/app/xinput/-/blob/xinput-1.6.4/src/test_xi2.c>
- Moonlight cryptographic pairing:
  <https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/nvstream/http/PairingManager.java>
- Moonlight NvHTTP catalog, launch, and unpair client:
  <https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/nvstream/http/NvHTTP.java>
- Sunshine authenticated client-removal implementation:
  <https://github.com/LizardByte/Sunshine/blob/v2026.914.233613/src/confighttp.cpp>
- Android Emulator graphics acceleration modes:
  <https://developer.android.com/studio/run/emulator-acceleration>

## Local source checks

The focused checks are:

```text
python3 -m unittest \
  tool.tests.f60_owned_gamepad_test \
  tool.tests.f60_sunshine_owned_host_test \
  tool.tests.f60_sunshine_android_stream_test \
  tool.tests.f60_sunshine_android_stream_workflow_test
python3 -m py_compile \
  tool/f60_owned_gamepad.py \
  tool/f60_sunshine_owned_host.py \
  tool/f60_sunshine_android_stream.py
actionlint .github/workflows/f60-sunshine-android-stream.yml
```

These checks validate the bounded control protocol, receipt parser, private
fixture material, fixed subprocess arguments, source guard, and artifact
allowlist. They do not replace the hosted stream run.
