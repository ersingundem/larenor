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
