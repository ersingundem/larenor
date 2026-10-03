# F60 owned connection boundary diagnostics — 2026-10-03

## Scope

This slice adds process-private, exact-launch-token observations for the real
embedded Moonlight `Game` callbacks. It does not retry a stream, change lease
ownership, advance a readback revision, notify a command observer, or turn a
callback into acceptance.

The pinned upstream source is commit
`b48494cb96bff23d8886c4775cc4f39a1075495d`. Its actual
[`Game`](https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/Game.java)
implements both `SurfaceHolder.Callback` and `NvConnectionListener`. It adds
itself as the stream surface callback, starts `NvConnection` from the first
valid `surfaceChanged`, reports connection phases through `stageStarting`,
`stageComplete`, and `stageFailed`, and reports the successful connection
boundary through `connectionStarted`.

## Closed observation shape

`MoonlightConnectionBoundarySnapshot` contains only the exact session ID and
epoch plus six monotonic booleans:

- `surfaceCreated`
- `positiveSurfaceChanged`
- `stageStarted`
- `stageCompleted`
- `stageFailed`
- `connectionStarted`

Stage names, error codes, dimensions, hosts, codecs, provider messages, and
throwable messages are not retained. `toString()` is redacted.

The callbacks update observations only while the exact token is
`TRANSFER_PENDING` or `GAME_VISIBLE`. A positive surface change requires both
dimensions to be greater than zero. Stale tokens and retiring or terminal
leases do not accept later observations. A successful or uncertain terminal
transition retains the already observed booleans for the separate
`terminalConnectionBoundarySnapshot(token)` failure-diagnostic read. Once a
successor replaces that terminal entry, the old token cannot read or mutate
the successor.

`connectionStarted` remains the only callback in this set that can advance the
normal stream lease. Its one synchronized registry operation records the
boundary while the token is active, then still requires an already claimed,
visible Game activity before changing authoritative state. A pending-transfer
regression proves the observation does not weaken the existing
`foreground_required` rejection, notify an observer, or produce a streaming
result. Keeping observation and transition under one lock also prevents a
claim or retirement from interleaving between the two decisions.

## Focused regression

`connectionBoundariesAreExactFiniteDiagnosticOnlyAndTerminalPreserved`
exercises the pending and visible states, invalid dimensions, all six finite
flags, unchanged diagnostic-only readback, the one existing connection-start
observer notification, terminal preservation, and stale-token isolation after
a successor issue.

`runtimeConnectionBoundaryDiagnosticFencesAuthoritySessionTerminalAndSuccessor`
binds the failure-only read to the runtime's exact authority, session ID,
session revision, and active launch token. Mismatched authority/session/revision
inputs retain the existing `authority_changed` failure. The regression also
checks that a diagnostic read changes neither lease state nor readback, that a
terminal lease retains its six booleans, and that replacement makes the old
registry entry unavailable before the runtime adopts the successor token.

The runtime captures and fences its token while holding its own lock, releases
that lock before reading the synchronized registry, then rechecks authority,
generation, session and token after the read. This matches the existing output
and terminal witness lock order and prevents a registry observer from entering
the runtime in the opposite lock order.

The source and regression are frozen without running Gradle because the shared
required-engine build window was explicitly unavailable. The planned focused
commands, once the receipted dual-native package and build window are released,
are:

```text
cd android
LARENOR_PRODUCT_NATIVE_ENGINES=required ./gradlew --no-daemon \
  :app:testDebugUnitTest \
  --tests com.ersingundem.larenor.game.moonlight.MoonlightEmbeddedRuntimeTest \
  -x :app:compileFlutterBuildDebug

LARENOR_PRODUCT_NATIVE_ENGINES=required ./gradlew --no-daemon \
  :app:compileDebugAndroidTestKotlin \
  -x :app:compileFlutterBuildDebug
```

The first command is the focused JVM/Robolectric regression. The second is
only a source/package compilation gate; neither command is a hosted Sunshine
stream receipt.

## Root publication checkpoint

The runtime accessor binds the callback snapshot to the captured authority,
session revision and exact launch token before and after the registry read.
The registry read runs outside the runtime lock. The owned test emits only six
booleans on its original strict failure path. The runner requires the original
named test, exact source hash, first-stream stage, canonical 1/1/0/0 counts
and one closed marker. Duplicate, malformed, stale-source, wrong-stage and
private-field markers cannot publish evidence. No success assertion is relaxed.

Root ran the runner suite: **54 passed / 36 subtests passed**; pinned Ruff
passed. Independent source/publication review found no P1/P2 issue. These are
local diagnostic tests, not Sunshine stream, render, PCM or input acceptance.

With the exact receipted dual-ABI product mounted, root independently read the
JUnit evidence: `MoonlightEmbeddedRuntimeTest` passed **46/46**, zero skipped,
failed or errored. The complete shared native gate passed **90/90** and
`compileDebugAndroidTestKotlin` passed. The runner workflow suite passed
**10 tests / 12 subtests** and actionlint passed. Hosted stream acceptance is
still required.
