# F62 post-resize failure diagnostics — 2026-10-01

## Scope

GitHub Actions run `36797967344` at source revision
`7fccce520ff8e1abcf45a16d6ffb4d16c8a72bb2` reached the owned NLA shadow
host, observed the exact XI2 A-key press/release, and changed and read back the
owned Xorg output at `1024x768`. Its one Android instrumentation method then
failed. The bounded public receipt reported `instrumentation_test_failure`, but
the exception was `unclassified` and no source frame survived sanitization.
That evidence narrows the failure to the resized-frame or teardown portion of
the method; it does not identify a product defect or justify a same-revision
rerun.

This change preserves the original one-test, zero-skip acceptance and all of
its assertions. It adds five fixed instrumentation exception classes around
the already-existing post-resize boundaries:

- `resizedFrameWait`
- `resizedFramePixels`
- `resizedFrameAck`
- `cleanClose`
- `credentialClear`

The public failure parser publishes `acceptanceStage` only when all of these
facts agree:

1. the JUnit report has the exact expected class and method identity;
2. counts are exactly one test, one failure, zero errors and zero skips;
3. the first throwable header is one of the five fixed classes when the XML
   has no `failure@type`, or the declared type is that exact fixed class when
   an exporter supplies it; and
4. the trace contains the exact owned acceptance method in
   `RdpPackagedHostAcceptanceTest.kt`.

This matches the resolved Android connected-test exporter rather than a
synthetic XML assumption. The project uses Android Gradle Plugin `9.4.1`, which
resolved `com.android.tools.ddms:ddmlib:32.4.1`. Bytecode inspection of that
exact artifact's `XmlTestRunListener.printFailedTest` shows it starts the
`failure` element, writes only the sanitized stack-trace text, and closes the
element; it does not write a `type` attribute. The inspected JAR SHA-256 is
`ad7b49fc07ca341d205fb7eb17cd0610a18cd1678e55b6b4a869bbdee3fbf0e3`.
The parser therefore recognizes an absent type only when the first throwable
header is the fixed class and the exact owned method frame is also present. A
generic `AssertionError` whose message merely contains a fixed class name does
not classify a stage.

Messages, fixture identities, pixels, credentials, raw paths, raw logs, and
arbitrary exception or stage strings are never copied into the public receipt.
A wrong test identity, wrong source, unknown class, or a known class name
injected only into message text remains unclassified or identity-mismatched.
The raw JUnit report remains private and is deleted after the bounded receipt
is written.

## Local evidence

```text
python3 -m unittest tool.tests.f62_packaged_acceptance_test
Ran 27 tests ... OK

python3 tool/freerdp_android_package.py verify-install <x86_64-aar> <receipt>
./gradlew --no-daemon :app:compileDebugAndroidTestKotlin \
  -x :app:compileFlutterBuildDebug --console=plain
BUILD SUCCESSFUL in 8s
277 actionable tasks: 6 executed, 271 up-to-date
```

The Android instrumentation source was compiled against a retained x86_64 AAR
accepted by the repository's receipt and source-lock verifier. The temporary
AAR mount was removed after compilation. A hosted result is still required:
these diagnostics classify a future changed-source failure; they are not
acceptance evidence and do not relax any TLS, NLA, certificate, rendered-pixel,
resize, ACK, close, or credential-clearing requirement.
