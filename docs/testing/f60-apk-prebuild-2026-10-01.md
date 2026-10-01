# F60 real APK prebuild — 2026-10-01

## Actual failure and correction

The exact `2af5e8cc48c7cf52aa98172f6d5369337a8fa822` discovery run
[36799033298](https://github.com/ersingundem/larenor/actions/runs/36799033298)
and stream run
[36799039362](https://github.com/ersingundem/larenor/actions/runs/36799039362)
both failed `:app:copyJniLibsflutterBuildDebug`. The fresh checkout excluded
`:app:compileFlutterBuildDebug`, so the required Flutter JNI input did not
exist. Neither run produced a terminal Android report or acceptance receipt.

Discovery and stream now share a bounded APK prebuild that actually executes
the Flutter task and assembles both the app and instrumentation APK. This
finishes before the owned Sunshine host starts, so compilation cannot consume
the provider's readiness or input deadlines. The connected instrumentation
invocation may exclude the Flutter task only after that successful prebuild.
A prebuild error prevents the provider from starting.

The first real local full prebuild passed Flutter/JNI production but exposed a
second independent failure: `:app:mergeDebugAndroidTestAssets` rejected runner
`1.7.0` because the Moonlight app runtime still resolved `1.3.0`. The existing
FreeRDP debug-runtime constraint now also applies when the receipted Moonlight
package is installed. It aligns the transitive debug runner with the already
declared instrumentation runner; it is not a global dependency force.

## Local evidence

The canonical Moonlight AAR SHA-256 is
`d327a45cb669afc4a9b6bfe9ee70406471c29ab6cab546cef6554500531336c5`;
its receipt SHA-256 is
`fe08b7d68210669416ce9ce0839bfd0afa0bc2c02feb989b6ccafdfe19fbc9f5`.
Both were independently checked and accepted by `verify-install` before the
temporary package mount. With Java 17 and the configured Android SDK:

```text
:app:assembleDebug :app:assembleDebugAndroidTest
BUILD SUCCESSFUL in 21s
400 actionable tasks: 59 executed, 341 up-to-date
moonlight_android_package.py verify-apk: passed
temporary package mount: removed
```

The actual source-locked APK verifier passed after the build. These results
prove local APK assembly and package linkage, including the current OSC
instrumentation source. They do not prove hosted discovery, pairing, stream,
gamepad, disconnect or feature acceptance.

Root also passed 128 combined gamepad/host/discovery/stream/workflow,
dependency-policy, queue and commit-progress tests after the effective ACL
correction. Both owned Android workflow files passed actionlint.

## Key-effect evidence integrity

The old XI2 key reader falsely accepted an A-key press followed by another
key's release and a Motion record containing `detail: 38`. Root reproduced
that false positive. The reader now clears event context at every event
boundary and uses byte-bounded lines, with a 4 KiB per-line and 64 KiB total
limit. Unknown events cannot complete the preceding release, truncated or
oversized lines fail closed, and unrelated UTF-8 device listings do not
invalidate a real A-key press/release. Focused regressions cover those cases.

F60 remains `reworking`; hosted effect evidence and physical controller,
rumble, latency, sound and quality gates remain open. The accepted counters
and the 58 selected / 67 total CI-waiting labels are unchanged.
