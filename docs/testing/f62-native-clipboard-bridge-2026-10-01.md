# F62 native client-to-remote clipboard bridge — 2026-10-01

## Supported production boundary

The Android method-channel bridge accepts one exact clipboard input shape:

```text
{requestId, sequence, kind: "channel", channel: "clipboard", payload: Uint8List}
```

The current RDP session must be foreground, current, and negotiated with
`clipboardMode=clientToRemote`. The payload must be non-empty strict UTF-8, at
most 65,536 bytes, and contain no NUL byte. It uses the session's shared input
sequence, so a replay or reordered clipboard submission is rejected like
pointer and keyboard input. The bridge and session wipe the caller-owned byte
array on success and every rejection path.

The receipted FreeRDP 3.31.1 package at source commit
`63b948ca5cb94307fd5444ee6e73927a41ccdab4` exposes
`LibFreeRDP.sendClipboardData`; the packaged runtime enables the clipboard
channel only when the negotiated mode requests it. Upstream's Android binding
is the production submission boundary:
[FreeRDP Android `LibFreeRDP`](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/client/Android/Studio/freeRDPCore/src/main/java/com/freerdp/freerdpcore/services/LibFreeRDP.java).

Android clipboard reads remain an explicit foreground user action. Android 10+
restricts clipboard access to the focused app or default IME, and Android 12+
shows a clipboard-access toast:
[Android copy and paste guidance](https://developer.android.com/develop/ui/views/touch-and-input/copy-paste).

## Focused evidence

The focused native gate ran with Flutter compilation excluded because a
concurrent Client clipboard hunk was incomplete at the start of this slice.
Kotlin production and unit-test sources compiled, then these exact classes
passed:

- `RdpNativeBridgeTest`: 3 tests, 0 failures, 0 errors, 0 skipped.
- `RdpFreeRdpEngineTest`: 12 tests, 0 failures, 0 errors, 0 skipped.

The new bridge regressions cover a multilingual valid payload plus disabled
mode, malformed UTF-8, embedded NUL, over-limit payload, unknown channel,
stale sequence, and background submission. Every negative case proves zero
runtime dispatch and byte-array erasure. The pre-fix focused run compiled and
failed both new bridge tests before the production handler was added.

The cached x86_64 FreeRDP AAR and receipt passed `verify-install`; with the pair
mounted under `android/app/freerdp`, `:app:compileDebugKotlin` completed
successfully. The temporary AAR and receipt were removed afterward. Logs:

- `/private/tmp/larenor-f62-clipboard-native/focused-final.log`
- `/private/tmp/larenor-f62-clipboard-native/packaged-compile.log`

## Honest boundary

This evidence proves strict native admission and accepted submission to the
packaged FreeRDP clipboard API. It does not prove remote clipboard readback.
The current owned shadow-server fixture does not implement `cliprdr`; a real
NLA-capable owned-host clipboard effect gate remains open. Bidirectional
clipboard, remote-to-client clipboard monitoring, audio, and file channels
remain unavailable and are not advertised.
