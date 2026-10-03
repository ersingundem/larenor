# F62 microphone native consumer evidence — 2026-10-03

## Scope

This slice adds a schema 4 Android consumer for the source-locked FreeRDP
microphone callback. It does not claim that a remote host received meaningful
audio. `acceptedCount` proves only that FreeRDP submitted the corresponding
AUDIN Data PDU to the channel.

The package identity is
`freerdp-3.31.1-63b948ca-display-pointer-audio-microphone-v4`, with JNI schema
4. The Java callback is `OnMicrophoneCapture(JZJJI)V`. It carries only the
native instance, an open flag, JS-safe monotonic captured/submitted counters,
and a fixed state. PCM, endpoint identity, credentials, and provider messages
never cross this boundary.

## Authority and permission boundary

- `microphone` defaults to `false` in the strict schema 4 request. Only an
  explicit `true` adds `microphone=sys:opensles` to the private FreeRDP URI.
- A dedicated RDP permission broker requests `RECORD_AUDIO`; it never starts a
  session or capture. The request is exact-owner, cancellable, deadline-bound,
  and completed after focus returns when an Android permission dialog granted
  while the Activity was unfocused. A prompt-related pause may retain that
  one pending request, while Activity stop, route cancellation, deadline, or
  bridge disposal cancels it.
- The packaged runtime retains the exact Activity weakly and independently
  rejects microphone creation unless that Activity is focused, not finishing
  or destroyed, and still holds `RECORD_AUDIO`. An application Context cannot
  authorize capture. The production reflective loader therefore passes the
  current Activity rather than replacing it with `applicationContext`.
- Open checks the permission and its scoped `RECORD_AUDIO` app-op before
  scheduling native work, immediately before native create, after create, and
  before publishing success. A public `AppOpsManager` listener observes only
  this package's `RECORD_AUDIO` changes, rechecks the actual permission and
  app-op, and retires the exact current microphone session on revocation.
- Non-microphone sessions are unaffected by microphone revocation. Disabled
  sessions cannot query a retained observation.

## Certificate boundary

Schema 4 also forces FreeRDP external certificate management. The packaged
probe and session override the new bounded
`OnVerifyX509Certificate(byte[],String,long,long)` callback, require one PEM
certificate of at most 64 KiB, bind it to the exact direct host and port, and
derive only the SHA-256 SPKI pin. A gateway-kind callback (`flags & 0x20`) is
rejected because RD Gateway remains unavailable. The legacy fingerprint and
changed-certificate callbacks always reject, so a platform trust-store result
or an old accepted-certificate cache cannot bypass the configured pin before
credentials.

## Observation contract

`microphoneObservation` returns the exact current request with state
`pending`, `opened`, `captured`, `sent`, `closed`, or `failed`, plus
`deviceOpen`, `capturedCount`, and `acceptedCount`. The constraints are:

- both counters are in `0..2^53-1` and never decrease;
- `acceptedCount <= capturedCount`;
- `captured` requires a real nonempty OpenSL recorder callback;
- `sent` requires `acceptedCount > 0` after successful AUDIN Data PDU
  submission;
- `closed` and `failed` are terminal for that session.

The packaged registry validates the exact native instance and request. Its
delivery path is single-consumer and coalesces to one retained snapshot, so a
producer cannot create an unbounded Java queue. Retirement drops pending
publication and native cleanup owns recorder quiescence.

## Evidence and remaining gate

Focused contract tests cover strict schema/defaults, package identity, fixed
states, monotonic counters, disabled and foreign sessions, permission
cancel/focus ordering, revocation, URI enablement, and actual-submission versus
capture-only observations. They also cover the Activity authority predicate,
strict single-PEM SPKI derivation, direct-peer callback kind, and caller secret
zeroization on permission rejection. Root mounted the verified schema 4 dual-ABI
AAR alongside the existing Moonlight package and ran the actual product:
78 RDP and 47 Moonlight JVM tests passed, with zero failures, errors, or skips.
The real AndroidTest Kotlin source compiled successfully in the same invocation
(315 tasks). Both private source manifests were checked unchanged after execution.
The SDK compile rejected a non-public permission listener; the final code uses
public, package-scoped `AppOpsManager.OPSTR_RECORD_AUDIO` observation. The final
SPKI encoder uses Java Base64, avoiding an Android stub in the JVM gate.
See the [composed root evidence](f62-owned-microphone-composed-2026-10-03.md).
Real acceptance additionally needs an owned NLA host to recognize a private
nonce-derived tone from the AUDIN channel; this slice alone is not that proof.
