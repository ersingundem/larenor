# F62 owned packaged-open boundary diagnostics (2026-10-03)

## Scope

This slice adds a failure-only, process-private diagnostic for one exact
`RdpPackagedRuntime` open operation. It does not change the native request,
FreeRDP package, public MethodChannel, connect deadline, retry policy, or any
acceptance criterion.

The 5122 hosted failure reached `firstSessionOpen` and surfaced the existing
closed `RdpNativeFailure("connectionFailed")`. That public code combines
several distinct boundaries. A successful certificate probe cannot distinguish
them because the probe intentionally rejects the certificate callback before
credentials, NLA, DISP negotiation, or a live session.

## Exact private contract

The hosted Android test may call only:

```text
RdpPackagedRuntime.consumeFailedOpenDiagnostic(requestId)
```

The internal accessor is scoped to that runtime instance. It returns null for
an active operation, a successful operation, a mismatched request ID, an
already consumed failure, or a failure superseded by a newer create. A matching
terminal failure is returned exactly once as
`RdpPackagedOpenDiagnosticSnapshot`.

The snapshot contains exactly seven boundary booleans:

1. `connectionInfoParsed`: pinned `setConnectionInfo` accepted the exact URI;
2. `connectAccepted`: JNI accepted the connect invocation;
3. `certificateAccepted`: the target certificate callback matched the expected
   SPKI;
4. `authenticatedConnectionSucceeded`: the existing `OnConnectionSuccess`
   authority ran after NLA;
5. `displayCapsObserved`: the exact instance received
   `OnDisplayControlReady`;
6. `initialLayoutAccepted`: the initial `sendMonitorLayout` returned true; and
7. `securityPublished`: authenticated security was delivered to the exact
   `RdpFreeRdpSession`.

It also contains `timeout` plus one closed terminal kind. Public wire values are:

```text
candidateCreateFailure
localSetupRejected
connectionFailureCallback
disconnectedCallback
retired
timeout
```

`NONE`/`none` is internal and cannot be consumed or published. Candidate
creation is recorded separately from URI parsing and connection setup.

These are observations rather than inferred failure causes. For example,
`connectAccepted=true` does not prove the peer was reached, absence of a
certificate callback does not prove TLS failed, and a display callback does not
prove the initial layout was accepted.

## Concurrency and retention

Each create installs a new recorder in its owning runtime before constructing
the operation. The slot retains only the last-created operation by object
identity. Starting a successor clears the previous failed record even if the
request ID is reused. A late callback can mutate only its retired recorder and
cannot make that recorder current again.

The first terminal observation wins. Later callbacks, timeout, retirement, or
cleanup cannot replace it or add later boundary bits. Authentication and DISP
callbacks may arrive in either order, but both remain bound to the exact native
instance through the existing FreeRDP registry. A successful open removes its
record at the start-success linearization point, so even a concurrent
post-accept retirement cannot leave a readable failed-open diagnostic.

Only the FreeRDP registry's actual `OnConnectionFailure` callback records
`connectionFailureCallback`. Initial-display application rejection and an
invalid remote-audio observation record `localSetupRejected` before invoking
their existing common terminal action. The first-terminal rule therefore keeps
those local setup failures distinct without changing connection teardown or
the public `connectionFailed` result.

The snapshot contains no native instance, host, port, username, domain,
certificate, credential, exception message, stack, PID, framebuffer, audio, or
provider data. The request ID is required as an accessor argument but is not
included in the snapshot.

## Root publication boundary

The root-owned Android test and runner may serialize the seven booleans,
terminal kind, timeout, and the separately caught closed `RdpNativeFailure.code`
only after the exact package/source/test/nonce and original
one-test/one-failure/zero-skip result are verified. The record remains a private
nonce-bound failure marker. It cannot replace the original Throwable, change a
JUnit result, authorize retry, or satisfy any TLS, NLA, frame, ACK, input,
resize, clipboard, audio, two-lifetime, or close gate.

## Focused regression scope

`RdpPackagedOpenDiagnosticTest` covers:

- active and successful operations returning no snapshot;
- success linearization clearing a concurrent post-accept retirement;
- exact-ID, single-use failure consumption;
- first-terminal-wins behavior and ignored late boundary observations;
- local display/audio rejection remaining distinct from the JNI connection
  failure callback;
- successor replacement with distinct and reused request IDs;
- DISP-before-authentication and authentication-before-DISP ordering;
- distinct candidate-create, setup, callback, disconnect, retirement, and
  timeout outcomes; and
- the closed terminal wire-value set.

The intended focused command is:

```text
./gradlew :app:testDebugUnitTest --tests com.ersingundem.larenor.rdp.packaged.RdpPackagedOpenDiagnosticTest
```

Root integrated the frozen slice with the actual schema-3 FreeRDP package and
embed-v4 Moonlight package. The required-native command passed **112 JVM tests**
(**65 RDP**, including **9 open-diagnostic tests**, and **47 Moonlight**) with
zero failures, errors, or skips. AndroidTest Kotlin compilation passed in the
same **314-task** invocation. This is working-tree integration evidence on
base `7a53e166844d4e124832b89ba8122c47ed42eb57`, not hosted runtime acceptance.

Root's runner suite passed **61 tests / 89 subtests**. The composed
package/runner/workflow/product/queue/progress gate passed **225 tests / 184
subtests**; Ruff passed. Independent review found no P1/P2 blocker in the
failure-only publication boundary. New compact markers reject leading or
trailing whitespace instead of silently canonicalizing it.

Private native evidence: `/private/tmp/larenor-v4-v3-native-gate-g0exo5qs/`.
The 22-file frozen source manifest SHA-256 is
`ac4dc3cbdc16d0a5e359da6e26a90cc796a586e2209cb472381ec9029666da67`;
log SHA-256 is
`a900c8ddc154beb1f5d9ec849086e1f0e781e21bfc535f2dd1147e5bf2e504ba`.
The exact AndroidTest source SHA-256 is
`d757674537550dc871bb8a428ba684f209908bdbf3354036d7b11e24f880afb0`.
F62 remains reworking: a changed-source owned host run is still required, and
microphone, real SAF transfer, and RD Gateway composition are still open.
