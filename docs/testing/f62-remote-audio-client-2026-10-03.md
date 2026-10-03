# F62 remote audio Client schema 3 — 2026-10-03

This slice adds remote sound as an explicit, per-open-profile choice. It starts
Off, can be chosen before connecting, and is locked during a live connection.
The microphone and files remain disabled. Existing profile-settings version 1
and immutable RDP contracts v1/v2 are retained; native session wire packets use
schema 3 and the new `contracts/rdp-client.v3.json`.

The controller rejects an unsupported audio request before certificate inspection
or credential prompts. Its one-second readback runs only on the authenticated,
current foreground connection. Each read has a five-second owned, cancellable
deadline. Close, disposal, or retirement resolves waiters, cancels deadline and
poll timers, and discards delayed responses; no readback sends an audio command,
reconnect, or replay. Overlapping callers share one native observation read.

The exact native observation contains only schema, request ID, the finite state,
device-open boolean, and accepted/completed counters. Unknown fields, a foreign
request, invalid state/boolean combinations, unsafe counts, completed greater
than accepted, counter regression, and revival from failed are rejected.
Device-close is a format lifecycle and may reopen with cumulative counters.
Pending and accepted-only buffers never display playback success; the UI reports
remote sound played only after a native buffer completion on the open device.
PCM, native stage strings, target data, and credentials are absent from readback.

Local verification: after source freeze, all seven RDP Flutter suites passed
**91 tests** with zero failures. This includes stuck-query close/dispose with
zero remaining timers, stale reply suppression, exact audio contract, capability
rejection before credentials, consent, and accepted-only versus completed
playback feedback. Whole RDP production/test analysis is clean. Independent
native/lifecycle review found no remaining DTO or cancellation blocker; both
owned deadline timers cancel, and late replies cannot revive the session.

This is Client software evidence, not a real sound acceptance result. The exact
schema-3 dual-ABI OpenSLES package, Kotlin gate, owned PCM host/emulator gate,
Windows/RD Gateway, microphone, SAF file transfer, and physical Huawei/DeX gates
remain separate. F62 and FINAL.FUNCTION are not accepted by this document.

Primary source constraints:

- [Pinned RDPSND receive path](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/channels/rdpsnd/client/rdpsnd_main.c): the output device opens on the first Wave/Wave2, so a pending zero-counter baseline must precede the owned-host tone arm.
- [Android OpenSL lifecycle](https://developer.android.com/ndk/guides/audio/opensl/android-extensions): Stop/Clear callbacks are not an audible-output acceptance signal.
- [Pinned OpenSL output implementation](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/channels/rdpsnd/client/opensles/opensl_io.c): the reviewed package separately tracks accepted enqueue and actual completion.
