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
7. Deliberate stop succeeds only after the production connection reports that
   `NvConnection.stop()` returned. Native then retires the exact local
   registration and binding. The host verifies that the exact private
   Sunshine client UUID captured after pairing is still present and enabled;
   a same-name replacement cannot satisfy this check.

An API success response, a delay, a process exit, or a connection-start callback
alone is insufficient for output acceptance.

## Private control boundary

The PIN channel carries one JSON line of at most 256 bytes with exact keys
`nonce`, `pin`, and `schemaVersion`. The listener binds an ephemeral
`127.0.0.1` port. Android connects to fixed loopback port `49361`, mapped for
the duration of the test with `adb reverse`. The nonce is a one-run 256-bit
value. The bridge closes after its first message.

The PIN is never written to a file, command argument, environment value, log,
JUnit report, public receipt, or artifact. Sunshine credentials, provider
addresses, TLS material, native binding identifiers, upstream app identifiers,
frames, and PCM bytes are also excluded from artifacts.

## Public receipt

The workflow may publish a receipt only after the exact named JUnit case passes,
the PIN bridge observes the paired client, the owned tone injector succeeds,
XI2 observes the key pair, deliberate stop completes, Native locally retires
the binding, and Sunshine still reports the exact same private paired-client
UUID. The UUID itself never enters the receipt. The receipt binds the
repository revision and Moonlight package hashes and exposes only bounded
proof booleans.

`streamAccepted: true` means only the named
`streamAndLocalRetirement` scope: real pairing, catalog, launch, frame, PCM,
software key effect, stop, and local binding retirement. The same receipt says
`featureAccepted: false`, `localBindingCleared: true`,
`providerPairingRemoved: false`, and records provider pairing removal as
`unaccepted`. Source implementation and local unit tests are not streaming
acceptance, and this partial scope does not complete F60 functional acceptance.

## Current unpair compatibility boundary

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
alive. This gate performs no administrative removal or restart; it proves the
paired client remains present after local retirement.

## Limits

The visual proof is an actual MediaCodec rendered-frame callback, not a pixel
comparison or a quality judgment. The audio proof is an accepted complete PCM
write, not physical audibility. The key witness is software input delivered to
the owned X11 server; it does not prove a physical keyboard. Physical display,
speaker, controller, Wi-Fi, latency, HDR, HEVC, AV1, DRM, and household-host
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

## Primary protocol sources

- Sunshine pairing and launch server:
  <https://github.com/LizardByte/Sunshine/blob/v2026.914.233613/src/nvhttp.cpp>
- Sunshine Linux PulseAudio sink implementation:
  <https://github.com/LizardByte/Sunshine/blob/v2026.914.233613/src/platform/linux/audio.cpp>
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
  tool.tests.f60_sunshine_owned_host_test \
  tool.tests.f60_sunshine_android_stream_test \
  tool.tests.f60_sunshine_android_stream_workflow_test
python3 -m py_compile \
  tool/f60_sunshine_owned_host.py \
  tool/f60_sunshine_android_stream.py
actionlint .github/workflows/f60-sunshine-android-stream.yml
```

These checks validate the bounded control protocol, receipt parser, private
fixture material, fixed subprocess arguments, source guard, and artifact
allowlist. They do not replace the hosted stream run.
