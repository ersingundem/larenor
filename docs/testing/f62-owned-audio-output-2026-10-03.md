# F62 owned remote-audio queue evidence (2026-10-03)

## Scope

This slice extends the source-locked FreeRDP 3.31.1 owned-shadow fixture and its single packaged Android acceptance case. It preserves the existing NLA, TLS/SPKI, framebuffer, frame-acknowledgement, keyboard, client-DISP, Unicode clipboard, two-lifetime, and clean-close gates. It adds a bounded remote-audio signal in the first lifetime and proves that audio is absent in the second lifetime.

The evidence is software-output evidence. A successful Android OpenSL ES buffer callback proves that a buffer accepted by the app's `SLAndroidSimpleBufferQueueItf` was consumed by the platform audio queue. It does not prove a speaker was audible, an HDMI receiver accepted the signal, or a physical output path met a quality target. Those remain physical manual acceptance.

## Source-locked server fixture

The existing `f62-owned-shadow-channels.patch` remains the first patch. `tool/patches/f62-owned-shadow-audio.patch` is applied second and is bound by its SHA-256 plus final hashes for every changed source file. The additional source file `server/shadow/shadow_rdpsnd.c` is also bound to the pinned 3.31.1 archive.

The audio patch:

- requires `rdpsnd` only in authenticated lifetime 1 and requires it absent in lifetime 2;
- selects a fixed PCM source format: stereo, 44.1 kHz, signed 16-bit;
- accepts exactly one private arm record, `LRNAUD01` followed by the existing 64-hex diagnostic nonce and EOF;
- sends exactly 2,205 PCM frames, one 50 ms server packet, only after RDPSND activation and the private arm;
- retains no PCM in the public receipt and zeroes the temporary sample array after `SendSamples` returns;
- stops and joins the private worker before stopping RDPSND, then frees the private state, so callbacks cannot use retired state;
- records WaveConfirm only as a bounded wire diagnostic. WaveConfirm never proves Android playback.

The private terminal audio witness is an exact 64-byte, mode-0600, descriptor-validated record. Lifetime 1 must have one activation, one nonce arm, one send call, one accepted server send, exactly 2,205 frames, and zero fixture errors. Lifetime 2 must have zero RDPSND join, activation, arm, send, confirmation, frame, and error counts. A third witness, unknown flag, extra byte, link, wrong mode, or inconsistent count is rejected.

## Android causal gate

Pinned FreeRDP OpenSL ES does not open the audio device at format negotiation. `rdpsnd_ensure_device_is_open()` opens it only when the first Wave/Wave2 data arrives. Therefore the test must not wait for `deviceOpen` before arming the server.

After the first framebuffer is rendered and acknowledged, the exact current authenticated session must report:

- `state=PENDING`;
- `deviceOpen=false`;
- `acceptedCount=0`;
- `completedCount=0`.

The test then persists the nonce-bound `audioEffectWait` lifecycle stage. The host runner observes that fixed stage and writes one arm record, then closes the arm pipe. The test accepts audio only when the same session reports `state=PLAYING`, `deviceOpen=true`, `completedCount >= baseline + 1`, and `acceptedCount >= completedCount`. `acceptedCount` means OpenSL enqueue succeeded while the native runtime retained the owned buffer. `completedCount` means the registered OpenSL buffer callback consumed that exact retained buffer before close.

The second request has `audio=false`. Its audio observation must fail with the closed `channelUnavailable` code, and the private server audio witness must remain all-zero. Neither a pending/device-open state, an accepted-only buffer, a WaveConfirm, nor the presence of RDPSND is success.

## Privacy and lifecycle

The diagnostic nonce, arm bytes, PCM samples, credentials, provider address, and private terminal witnesses remain private. The public success receipt adds only bounded booleans and counts: one enabled server audio packet, zero disabled audio packets, bounded WaveConfirm count, and Android queue completion. The public receipt explicitly lists physical audibility as unproven.

The arm pipe is single-use and inherited only by the exact owned shadow process. The worker requires the full nonce record plus EOF, rejects trailing or duplicate bytes, and is joined before RDPSND teardown. Both authenticated lifetimes run in one owned shadow process, and all audio state is per-client; a retired first lifetime cannot authorize the disabled successor.

## Verification boundary

Portable tests validate archive/patch/final-source identities, sequential patch application, build flags, strict private witness parsing, one enabled/one disabled lifetime, arm framing, public receipt shape, runner phase order, and hostile witness cases. The Android source is compiled only after the receipted schema-3 FreeRDP package is installed. A hosted pass is still required before this can be called actual remote-audio acceptance; local parsing and compilation do not substitute for that run.

Root independently reviewed the private arm framing, activation-before-send,
per-client enabled/disabled lifetimes, completion causality and teardown order.
The fresh pinned archive plus both immutable fixture patches passed all final
source hashes. Combined fixture/package/workflow/product/queue gates passed
158 tests and 94 subtests; Ruff and actionlint passed. AndroidTest compilation
passed with the real schema-3 package. The Linux fixture binary and actual
remote PCM acceptance remain hosted gates. The CLI also retains Python 3.9
import compatibility through deferred annotations.
