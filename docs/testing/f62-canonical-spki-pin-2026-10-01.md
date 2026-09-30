# F62 canonical SPKI pin — 2026-10-01

Exact source `1259f39e7c734a3eaaa0a96cd0f032318295bf46`, hosted run
`36786452264`, passed the arm64 package/APK lane. Its bounded x86 failure receipt
identifies the original `RdpPackagedHostAcceptanceTest` method with one test,
zero skips, one failure and zero errors. The approved stack frames locate the
failure in `RdpNativeRequest.parse` / strict text validation, after both actual
JNI URI parser checks and the owned host's TLS certificate inspection.

The production PEM-to-SPKI encoder used Android `Base64.NO_WRAP`, retaining the
trailing `=` padding. It returned 51 characters including `SHA256:`, whereas the
unchanged Native Request contract requires exactly 50: prefix plus 43 unpadded
Base64 characters. The encoder now also uses `Base64.NO_PADDING`. The original
instrumentation method explicitly checks that shape before constructing its
strict request. TLS/NLA, certificate identity comparison, clipboard policy and
the real frame/input/resize/clean-close conditions are unchanged.

The safe failure artifact is
`freerdp-3.31.1-1259f39e7c734a3eaaa0a96cd0f032318295bf46-failure-diagnostics`.
Its package-receipt SHA-256 is
`cecfb0500f7c1de043b5fc08480c42861f8598d36e2a3e38ac2e0a1dfaaa9ce1`;
both owned FreeRDP host packages were `3.32.0+dfsg-0ubuntu0.24.04.1`.
Raw reports, credentials and certificates were not read or published.

Root verified the cached FreeRDP AAR against its receipt, then compiled the
changed production and original instrumentation Kotlin source sets and ran
`RdpNativeContractTest`: 7 tests, zero skips, failures or errors. Gradle passed
315 tasks (28 executed, 287 up-to-date). The temporary local AAR mount was
removed after the gate.

A changed-source hosted acceptance result is still required before this
software gate closes. F62 remains implementation-complete and awaiting real
native acceptance; this failing run is not a completion receipt.
