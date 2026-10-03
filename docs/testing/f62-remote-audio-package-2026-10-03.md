# F62 Android FreeRDP remote-audio package evidence (2026-10-03)

## Scope

This slice source-locks a fourth FreeRDP 3.31.1 Android patch for real remote-audio playback observation. It does not promote F62 acceptance and does not cover microphone redirection, SAF drive redirection, audio latency, speaker hardware quality, or a real owned-host tone witness.

The package identity is `freerdp-3.31.1-63b948ca-display-pointer-audio-v3` with JNI schema 3. The prior certificate, clipboard UTF-8, and display/pointer patches remain ordered and immutable before `android/freerdp-remote-audio-v3.patch`.

## Reviewed upstream contract

- FreeRDP's pinned Android options enable OpenSL ES by default: [ConfigOptionsAndroid.cmake](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/cmake/ConfigOptionsAndroid.cmake).
- `/sound:sys:opensles` selects the Android output subsystem and `/audio-mode:0` enables remote audio: [cmdline.c](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/client/common/cmdline.c).
- The pinned rdpsnd client acknowledges receipt before and immediately after handing audio to the device, so WaveConfirm is not playback-completion evidence: [rdpsnd_main.c](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/channels/rdpsnd/client/rdpsnd_main.c).
- The unpatched OpenSL backend used an infinite queue wait, ignored the OpenSL `Enqueue` result, and freed queued buffers from the buffer callback: [opensl_io.c](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/channels/rdpsnd/client/opensles/opensl_io.c).
- Android documents that buffer-queue callbacks can occur because of STOP or Clear, so teardown callbacks cannot be counted as playback completion: [Android OpenSL ES extensions](https://developer.android.com/ndk/guides/audio/opensl/android-extensions).
- The RDP audio virtual channel transports server audio to the client, but protocol receipt is not local playback proof: [MS-RDPEA](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpea/b408d629-1737-4011-80d8-7582044fb0ff).

## Fixed observation contract

`LibFreeRDP.EventListener.OnRemoteAudioPlayback(long, boolean, long, long, int)` is the only new public callback. It exposes no PCM bytes, format payloads, host values, credentials, or provider identifiers.

The fixed states are:

- `REMOTE_AUDIO_DEVICE_OPENED = 1`: OpenSL engine, output mix, player, buffer queue, internal queue state, and PLAYING state were created successfully.
- `REMOTE_AUDIO_BUFFER_ACCEPTED = 2`: the exact owned copy was retained and the OpenSL queue returned `SL_RESULT_SUCCESS`.
- `REMOTE_AUDIO_BUFFER_COMPLETED = 3`: the exact accepted buffer was removed by the OpenSL buffer callback while `closing == false`.
- `REMOTE_AUDIO_DEVICE_CLOSED = 4`: writers were cancelled, STOP/Clear ran, the player was destroyed, callbacks quiesced, queued buffers were released, and remaining OpenSL objects were destroyed. A later format can reopen the device.
- `REMOTE_AUDIO_FAILED = 5`: device creation, bounded queue admission, enqueue, or callback quiescence failed. The current native operation must retire.

Accepted and completed counts are per exact FreeRDP instance/plugin lifetime, monotonic, and preserve `completed <= accepted`. Reaching JavaScript's safe integer maximum is terminal on the next accepted or completed callback rather than silently repeating a count. Snapshot mutation and publication share one per-plugin lock, so a later accepted count cannot overtake an earlier completion snapshot. The callback is synchronous on the originating FreeRDP/OpenSL thread; consumers may only snapshot and signal from it.

## Lifecycle changes

The patch replaces the infinite producer wait with a 2-second cancellation-aware wait. It records acceptance only after successful OpenSL enqueue and orders acceptance before a possible immediate completion callback. Teardown marks the stream closing before STOP/Clear and destroys the player before waiting for active callbacks. If an active callback has not returned after 2 seconds, the fixed failure is published once and the private cleanup executor keeps the entire FreeRDP session/context graph alive until the callback actually quiesces. Only then are callback-owned buffers, OpenSL objects, the plugin, and the parent session eligible for release. UI and connection retirement remain bounded; native cleanup may remain quarantined rather than expose a late callback to freed parent state.

The OpenSL plugin publishes a source-bound FreeRDP PubSub event. The Android client registers that event per connection, subscribes during pre-connect, unsubscribes after final disconnect, and forwards only the fixed snapshot to Java.

## Verification

- `python3 -B tool/freerdp_android_package.py verify-lock`
- `python3 -B tool/freerdp_android_package.py verify-source /private/tmp/f62-owned-shadow-research/asset/freerdp-3.31.1.tar.gz`
- `python3 -B tool/freerdp_android_package.py verify-patch <prepared-source-root>`
- `python3 -B -m unittest tool.tests.freerdp_android_package_test` — 17 tests passed.

The package verifier rejects stale schema-2 Java contracts, a missing/wrong audio callback descriptor, altered public state values in either source or compiled `LibFreeRDP.class`, an unbounded queue wait, ignored OpenSL enqueue failure, completion during closing, patch reordering, reviewed-source drift, and receipt/native-evidence drift.

## Actual package build

The final fourth patch SHA-256 is `d0c6a07304bbdda398d5238d40bf8ae90996660a211e5f380a7f50bc90b89142`. The first compile attempt exposed an incomplete `rdpContext` use in the new channel-error path and produced no AAR. The corrected patch includes the public FreeRDP context definition and uses public `ERROR_INTERNAL_ERROR`; source verification and both sequential ABI builds then passed. Reusing the prepared source initially left a generated x86 JNI directory in the arm64 package input. The receipt verifier rejected that mixed-ABI AAR, no receipt was admitted, and each final package was rebuilt after removing only the other generated ABI directory.

The final private artifacts are:

- `arm64-v8a`: `/private/tmp/larenor-f62-audio-v3-build-20261003.0cdQQX/arm64-v8a/freeRDPCore-arm64-v8a.aar`, SHA-256 `6a87f0429268b3524c5f56f8f4f6b19e42ea6b2a363f6eb4856bafcdc7923e52`; receipt SHA-256 `60fcd79464868c8f8653c9608cefe52af6aec357c647d88d0954ed10534f2d65`.
- `x86_64`: `/private/tmp/larenor-f62-audio-v3-build-20261003.0cdQQX/x86_64/freeRDPCore-x86_64.aar`, SHA-256 `56b4926b9b6b51cdeaf2dbb87457e2b182e73b3d38428f6b1db49c9e392477fe`; receipt SHA-256 `11062c91817890789dfcf0c0640a1f9e0f8fd9b395373a95a35761cca6628b75`.

Both packages have the same compiled classes SHA-256, `db45e96add875fafe4784ce15efb7ae4d928bc247e301aa71d34ae985e587390`. The strengthened verifier read the five fixed integer states and `(JZJJI)V` callback directly from these compiled classes, verified the exact ABI ELF machines and four required native libraries, and accepted both receipts. A fresh source tree at `/private/tmp/larenor-f62-audio-v3-final-verify.RuAu1w/freerdp-3.31.1` also passed all four ordered patches and the source-bound checks.

The schema-3 packages have not been mounted into the shared application in this slice. Native consumer compilation, product packaging, and a causal owned-tone playback witness remain required. Package construction and callback counters do not by themselves prove audible output, hardware quality, or remote-host audio acceptance.

## Root product mount

Root independently checked both AAR/receipt hashes and exact ABI identity,
assembled and verified the complete required-mode product, and preserved the
previous schema-2 package for recovery. The merged schema-3 AAR SHA-256 is
`edc6a1dc6f4994c4052abe8293ace20580d1332d985eaf19956899ad6616f2ec`;
the product receipt SHA-256 is
`4f28cef5435278c72346aa72449d3076a83ed0e67140e50665c91d26ae73d36b`.
The mounted pair passed the actual RDP native gate (56 tests, zero skips,
failures or errors) and AndroidTest Kotlin compilation. This does not replace
the owned-host audio completion receipt.
