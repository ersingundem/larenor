# F60 — source-bound phase bridge failure observation

Prepared on base `23516304565026a06119f2e4e51bd7ba7dfba4e1`, 3 October 2026.
The previous strict run failed waiting for the `touch_ready` response after
frame/nonzero-audio checks. The actual Linux XI2 probe passed separately; it
does not identify the integrated failure's cause.

The host phase bridge now exposes only a closed `stage/state/error` tuple in
the existing source/package-bound **failed** receipt. The fixed stages
distinguish audio injection, waiting for Android's touch request, starting the
XI2 listener, sending the touch acknowledgement, observing effects and later
gamepad/disconnect/cleanup work. No exception text, command, address, nonce,
identifier, coordinate or provider output is copied into the receipt. A lock
protects the snapshot and the first failure survives a later cleanup failure.

The post-Gradle host wait also captures this secondary evidence and rethrows
the original failure. Its code is `host_phase_bridge_failure`; it does not
invent Android failure counts when Android's XML reports success. Receipt
failure never replaces the original connected-test or host-wait result.

Root reran **74/74** stream/workflow tests and scoped Ruff 0.14.1. Tests use
real private socket exchanges to distinguish audio timeout from XI2 startup
failure, verify no touch/gamepad effect is accepted, preserve the first failure
across cleanup, reject non-enum/private fields and validate source-bound
receipt output and post-Gradle failure propagation. Independent review found
the post-Gradle capture gap; the fix and regression close it.

Success receipt generation, exact named XML identity, zero-skip requirement,
two stream lifetimes and host touch/gamepad/disconnect proof remain unchanged.
No runtime failure is declared fixed by this diagnostic slice. F60 remains
`reworking`; a single changed-source strict run is the next acceptance gate.
