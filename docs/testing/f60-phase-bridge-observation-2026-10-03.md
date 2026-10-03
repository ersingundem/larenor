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

## Changed-source terminal result

Exact `54954a768a5c97e7844e94bdeb46c445f54958c0` [strict run37131893719](https://github.com/ersingundem/larenor/actions/runs/37131893719) failed. Original named XML counts are 1test/1failure/0error/0skip at `ownedInputEffects`; the preserved phase tuple is `touchListener/failed/contract`, with `pinBridgeStage=pairedClientObserved`. The touch-arm ACK was never sent: the host failed while starting its real XI2 listener after the first frame/audio stage. This narrows the failing boundary; it does not establish the underlying readiness/probe/format cause or Android input ordering.

Root validated the canonical 1150-byte artifact against the closed production diagnostic validator, exact run SHA, named test, classes hash and receipted Moonlight source/engine identity. Artifact SHA256: `a09f1191b1f607e7223066968e272b4e45302c4115da116d21300da7edebd528`. CI AAR SHA256 `688b6771bcde7547465cd720fe8d157bada9af4ef88fdbc5575497bf3c0c6a1d` differs from the local build container hash; identical source/classes identity was checked separately. The private job log remains mode0600 (SHA256 `246c29c621fc1e0e3a2104fbf347d0ff4e531dc7bda36618e8fd4337454e8682`); no raw provider output is published. No rerun of this exact SHA is scheduled. F60 remains reworking; acceptance/merge counters are unchanged.
