# F60 actual Android JUnit aggregate — 2026-10-01

Run36801358423 at exactd69cb0bdaecda35e5a7a927dc2f4cfd93ffe1a01 completed
real400-task app/test APK prebuild and returned success from instrumentation
Gradle, then failed the discovery receipt parser with its fixed aggregate error.
No public discovery receipt was created. Successful Gradle execution alone does
not prove the required named one-test, zero-skip report; raw report XML was not
retained and this old run is not retrospectively promoted.

The actual AGP9.4.1 dependency ddmlib32.4.1 JAR was independently hashed:
`ad7b49fc07ca341d205fb7eb17cd0610a18cd1678e55b6b4a869bbdee3fbf0e3`.
`javap -private -c com.android.ddmlib.testrunner.XmlTestRunListener` confirms that
its result writer opens `testsuites`, writes tests/failures/errors/skipped
aggregate attributes, and writes child `testsuite` reports with the same counts.
The previous discovery and stream parsers required a direct `testsuite` root.

The shared parser accepts either the direct suite or this exact one-child
aggregate. For a wrapper it requires exactly one direct child, one total suite,
and exact1/0/0/0 counts on both wrapper and child. Each caller still requires its
own exact class/method, exactly one testcase, no failure/error/skipped element,
one bounded report file, and existing path identity checks. Empty, duplicate,
nested, unrelated, skipped, failed and count-drift reports remain rejected.

Two regressions reproduced the old parser rejection before the fix. Root then
passed107 discovery/stream/gamepad/queue/progress tests and scoped actionlint for
both workflows. These are parser checks, not a native or provider receipt. A new
changed-source hosted run is required before discovery acceptance.

## Exact changed-source Android discovery acceptance

[Run 36802851003](https://github.com/ersingundem/larenor/actions/runs/36802851003)
completed successfully at exact source
`5fa91e438806decc81d24c4e8a28058bbd53cea3`. Artifact `11136711855` has the
exact expected discovery name, is unexpired, and is bound to that run and SHA.
Root and an independent agent verified the canonical public receipt:

- SHA-256: `d19770971cfcca4069b031e9a61564a65b4ea829a29179f70c3ce448ad81d619`
- Gate: `owned_sunshine_android_discovery`
- Exact production class: `com.ersingundem.larenor.game.moonlight.MoonlightOwnedSunshineDiscoveryTest`
- Exact method: `discoversTheExactOwnedSunshineServiceAcrossFreshDiscoveryLifetimes`
- Tests: **1**, failures/errors/skipped: **0** each
- Fresh discovery lifetimes: **2**
- Pinned Sunshine tag: `v2026.914.233613`, service `_nvstream._tcp`
- `streamAccepted=false`

The receipt's source revision, embedded Moonlight engine revision, upstream
commit/tree and bounded AAR/classes digests match the reviewed package contract.
GitHub metadata independently shows successful engine build/install, real
Android NSD execution and receipt upload. This is discovery acceptance only;
stream/frame/PCM/input/gamepad/disconnect acceptance remains open.

The same-source [stream run 36802861944](https://github.com/ersingundem/larenor/actions/runs/36802861944)
has a cancelled stream step after emulator boot, during early APK prebuild.
No named instrumentation test, build/test failure, provider failure code or
receipt was observed; exact owned cleanup succeeded. GitHub initially retained
an `in_progress` run/job with no conclusion although all steps were terminal.
The four-minute step did not exhaust the job or subprocess timeout. The
external cancellation cause is unproved, so it neither establishes a product
failure nor satisfies the stream gate.
