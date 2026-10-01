# F60 PIN transport observation — 1 October 2026

The exact `36269cf05091156ae960106eaec27810ff35fc78` hosted stream run
`36813869676` reached the canonical Android test and failed with one test, one
failure, zero errors and zero skips. Its source-bound frame identified
`pairingRegistration`, while the only PIN bridge observation was `listening`.
That evidence does not establish whether Android never connected, the loopback
peer was rejected, the canonical frame was truncated or malformed, or a later
pairing operation stalled. It therefore does not prove a provider root cause.

The host bridge now records fixed, secret-free transport observations before
the existing pairing observations. The new values are `connectionAccepted`,
`connectionRejected`, `peerVerified`, `peerRejected`, `readRejected` and
`parseRejected`. They contain no address, port, nonce, PIN, exception message
or provider response. Cancellation does not create a transport failure value.
The previously reviewed values from `pinReceived` through
`pairedClientObserved` and their meanings are unchanged.

The connected-test child now runs in its own process group with stdin, stdout
and stderr connected to `DEVNULL`. While it is alive, the runner observes a
terminal bridge failure and stops and reaps only that exact owned group. It
uses bounded TERM and KILL waits and also reaps the child at the existing
absolute Gradle deadline. A Gradle process that has already completed keeps
its original return code; a simultaneous bridge observation is secondary and
cannot turn that result into success or replace its failure. A bridge failure
that arrives just after Gradle exits is still captured by the existing bounded
bridge join before any success receipt is possible.

Test-first regressions reproduced the old ambiguity: a real loopback client
that closed before newline remained `listening`, a newline-terminated invalid
JSON object also remained `listening`, and the runner had no way to observe a
terminal bridge failure while Gradle was active. The implementation now maps
those two socket cases to `readRejected` and `parseRejected`, respectively.
Additional regressions cover listener and foreign-peer rejection, timely and
late bridge failure, cancellation, absolute timeout, exact child reaping,
private subprocess streams, and preservation of an already-completed Gradle
failure.

Local focused result:

```text
python3 -m unittest -v tool.tests.f60_sunshine_android_stream_test
# 44 tests, 0 failures, 0 errors, 0 skipped
```

Root independently ran stream plus discovery tests: 60 passed, zero failures,
errors or skips. The unchanged stream workflow contract passed another 10
tests. These checks cover the diagnostic and process ownership changes; they
do not establish a hosted stream result.

The original acceptance boundary is unchanged. Success still requires the
single exact named Android test with zero skips/failures/errors plus real
discovery, pairing, catalog, rendered frame, full PCM, input effects, both
stream lifetimes, remote disconnect and local retirement. This diagnostic
slice is not a hosted Sunshine acceptance result. A changed-source hosted run
is required to learn which fixed transport or later pairing stage fails.
