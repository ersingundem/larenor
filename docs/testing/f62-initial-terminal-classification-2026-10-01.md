# F62 initial-frame terminal classification — 2026-10-01

## Observed boundary

Run `36819574142` at source `57f929459a22ab6082e400194e31e0162545f672`
passed the arm64 package job. Its x86 packaged-host job retained the original
named Android test with **1 test, 1 failure, 0 errors and 0 skips**. The public
receipt binds the failure to `initialFrameWait`,
`RdpOwnedInitialFrameTerminalFailure`, owned source frames, and
`serverResizeRequested=false`.

The receipt contains no lifecycle marker or native failure code. It therefore
does not distinguish connection failure, frame backpressure, framebuffer
rejection, stale session or an explicit cancellation. The private job log adds
no bounded native classification. No one of those causes is inferred here.

Android's `ApplicationProvider.getApplicationContext()` returns the context of
the application under test, so writing the nonce-bound marker in that target
application's `filesDir` is the intended context boundary:
<https://developer.android.com/reference/androidx/test/core/app/ApplicationProvider>.
The missing host observation remains a diagnostic transport gap rather than
evidence that the test did not reach its terminal branch.

## Source-bound diagnostic

The instrumented test now chooses one fixed throwable class from the captured
terminal session tuple:

- failed / `connectionFailed`
- failed / `frameBackpressure`
- failed / `framebufferUnavailable`
- failed / `staleSession`
- cancelled / no failure code

Every other tuple retains the generic terminal throwable. The test captures
phase and code once, uses the same values for the private marker and throwable,
and does not expose provider text, credentials, pixels or addresses.

The host parser accepts a throwable-derived terminal classification only when
all of these facts remain exact: the source-locked Android test SHA-256, named
class and method, one test with one failure and zero skips/errors, a known
throwable, and an owned test source frame. A valid marker that conflicts with
the throwable is rejected. If the source hash changes, the fixed throwable is
downgraded to an unclassified failure rather than publishing stale line or
semantic evidence.

This changes diagnostics only. It does not relax the 30-second frame deadline,
TLS/NLA/SPKI checks, rendered-pixel requirement, frame acknowledgements, input,
DISP resize, Unicode clipboard, two authenticated lifetimes or clean close.
The next changed-source hosted run is still required to reveal the actual
terminal tuple and to test any production repair.

## Focused validation

- `python3 -m unittest tool.tests.f62_packaged_acceptance_test`: 44 passed.
  The focused cases cover all five tuples, source-hash drift, wrong method
  identity, unowned or absent stage evidence, count/skip enforcement, and
  marker/throwable conflict.
- `:app:compileDebugAndroidTestKotlin -x :app:compileFlutterBuildDebug` with
  the installed two-ABI FreeRDP package: `BUILD SUCCESSFUL` in 12 seconds,
  277 tasks (6 executed, 271 up-to-date). This compiles the fixed classifier
  and its Android instrumentation regression; it is not provider acceptance.

Root independently repeated the exact Python gate: **44 passed**. The pinned
Ruff check passed after removing one unused test variable. The changed-source
hosted run remains necessary; these local checks are diagnostic evidence only.
