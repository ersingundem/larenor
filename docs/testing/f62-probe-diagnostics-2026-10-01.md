# F62 packaged probe diagnostics

## Evidence that required the change

The x86_64 packaged acceptance at source revision
`78b2881504ae0b6d02eb26421d57c663f39c2bd8` built the receipted FreeRDP
AAR and Larenor APK, enabled hosted KVM, and started the owned NLA shadow
server. Its one instrumented test then failed in `RdpPackagedRuntime.inspect`.
This is the exact
[GitHub Actions run](https://github.com/ersingundem/larenor/actions/runs/36779907094).
The public diagnostic proved that the expected class and method executed once,
but its `suiteExpected=false` field showed that the report root was not the
direct `testsuite` shape accepted by the parser. The raw XML was deliberately
deleted, so a one-suite Android aggregate is the bounded working inference,
not retained proof of the exact raw tag structure.

The owned frames ended at the probe's generic `engineUnavailable` path. They
could not distinguish a timeout from a connection failure before certificate
observation, a certificate callback without PEM evidence, or a PEM parse
failure. Raw JUnit output was correctly excluded from the public artifact.

## Bounded diagnostic contract

The packaged runtime keeps the existing public `engineUnavailable` failure and
the existing certificate callback return values. A private cause records one
of four fixed outcomes solely for the hosted acceptance parser:

- `timeout`
- `connectionFailureBeforeCertificate`
- `certificateCallbackMissingPem`
- `certificateParseFailed`

The cause contains no address, username, certificate, credential, exception
message, or platform stack. Production MethodChannel callers still receive
only the existing safe public failure code. The uploaded diagnostic accepts an
outcome only when it finds exactly one known marker and an allowlisted
`RdpPackagedRuntime.kt` frame.

The report parser now accepts either one direct `testsuite` or one
`testsuites` aggregate containing exactly one `testsuite`. Aggregate and child
test/error/failure/skip counts must match. The expected class and method must
still execute exactly once; skipped, additional, missing, or renamed tests
remain rejected. If a later report uses another structure, the public failure
contains only the fixed shape `aggregate` or `unsupported` and a bounded child
suite count. Raw tags, attributes, messages and report content remain private.

At the diagnostic revision Larenor used the FreeRDP 3.31.1 Android
`SessionState.connect` path to apply the URI and begin the native connection;
certificate verification reaches the session UI listener. The subsequent
[URI parser repair](f62-freerdp-uri-parser-contract-2026-10-01.md) checks
`setConnectionInfo` before directly starting native `connect`. Larenor continues to request PEM certificate evidence
before deriving its SPKI SHA-256 pin. See the pinned upstream
[`SessionState.java`](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/client/Android/Studio/freeRDPCore/src/main/java/com/freerdp/freerdpcore/application/SessionState.java)
and
[`LibFreeRDP.java`](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/client/Android/Studio/freeRDPCore/src/main/java/com/freerdp/freerdpcore/services/LibFreeRDP.java).

## Local verification

The focused parser and receipt suite verifies both XML shapes, exact aggregate
count agreement, all four outcomes, secret removal, duplicate/unknown marker
rejection, and the owned-frame requirement:

```text
python3 -m unittest tool.tests.f62_packaged_acceptance_test
19 tests passed
```

The related package, dependency and workflow suites also pass:

```text
python3 -m unittest tool.tests.f62_packaged_acceptance_test \
  tool.tests.f62_android_dependency_test \
  tool.tests.freerdp_android_package_test \
  tool.tests.freerdp_android_workflow_test
34 tests passed
```

The packaged Kotlin source was compiled against a previously retained,
receipt-verified x86_64 FreeRDP AAR for the exact pinned 3.31.1 source commit:

```text
python3 tool/freerdp_android_package.py verify-install <aar> <receipt>
./gradlew --no-daemon :app:compileDebugKotlin \
  -x :app:compileFlutterBuildDebug
BUILD SUCCESSFUL
```

The AAR and receipt were mounted only for the compile and removed afterward.
They are not repository inputs.

No hosted workflow was redispatched for this diagnostic-only slice. A later
exact hosted run is still required to identify the real probe outcome and to
prove the packaged NLA/frame/input/resize/clipboard/close path.

## Observed diagnostic result

Exact `bc65ac5ab55f9d3709660c6bc1dc894d80c93454`,
[run36784045011](https://github.com/ersingundem/larenor/actions/runs/36784045011),
finished with the expected original method executed once, zero skips/errors,
and one failure. Its public receipt records
`connectionFailureBeforeCertificate`; no raw JUnit, native message or secret
was read or exposed. Both source and test identities were checked by root.
The production URI/parser repair is documented separately; F62 remains test
pending until the changed native path passes the real owned-host receipt.
