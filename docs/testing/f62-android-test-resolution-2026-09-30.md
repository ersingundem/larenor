# F62 Android instrumentation dependency resolution

[Hosted run 36768544534](https://github.com/ersingundem/larenor/actions/runs/36768544534)
at revision `ebf00c06` built both APK/AAR lanes and started the owned x86 host,
but instrumentation never launched. `:app:mergeDebugAndroidTestAssets` failed
because the test APK requested stable `androidx.test:runner:1.7.0` while AGP's
consistent resolution inherited strict runner `1.3.0` from the app's
`debugRuntimeClasspath`. Dependency insight identifies Flutter's
`integration_test` plugin as the old transitive request.

This is an app/test classpath issue rather than a native RDP protocol failure.
Android's official
[dependency-resolution guide](https://developer.android.com/build/dependency-resolution-errors#fix_conflicts_between_classpaths)
states that the app runtime determines matching versions in the test APK
runtime. The official
[AndroidX Test release table](https://developer.android.com/jetpack/androidx/releases/test#declaring_dependencies)
lists runner `1.7.0` as the stable instrumentation dependency. Gradle's
[dependency-constraint guide](https://docs.gradle.org/current/userguide/dependency_constraints.html)
recommends a constraint when a build must control a transitive version without
adding a new dependency.

The packaged FreeRDP build therefore constrains the existing transitive runner
on `debugRuntimeOnly` to `1.7.0`, and only when the receipted FreeRDP package is
present. The normal app and release runtime are unchanged. There is no global
force rule and the test APK retains the official `androidTestImplementation`
dependency.

Local dependency insight with the receipted-package branch active resolved both
`debugRuntimeClasspath` and `debugAndroidTestRuntimeClasspath` to runner
`1.7.0`; the latter reported the exact strict `1.7.0` constraint inherited by
consistent resolution. The focused policy test verifies the scoped constraint,
the matching stable test dependency and absence of a global force. This proof
only clears dependency resolution. A new hosted run must still execute the
strict one-test/no-skip NLA acceptance before F62 can claim interoperability.

## Moonlight scope correction — 2026-10-01

A real full Moonlight app/test APK prebuild reproduced the same strict
`1.3.0` versus `1.7.0` conflict at `:app:mergeDebugAndroidTestAssets`.
The debug-runtime constraint now covers `hasFreeRdp || hasMoonlight`, matching
the already shared instrumentation dependency scope. A receipted Moonlight
full prebuild then passed all 400 tasks and its source-locked APK verifier.
This establishes dependency/build compatibility only; the owned hosted
Sunshine gate is still required. See [F60 prebuild evidence](f60-apk-prebuild-2026-10-01.md).
