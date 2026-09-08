# Managed volume CREATE fixture lifecycle repair

8 September 2026. Isolated base:
`32d43fd54f7213b3d2cf548dcda7c86b05310606`. This is a test-fixture repair;
no Server production, Client, contract, Android, workflow or timeout setting
changes. No Docker daemon, live home or external endpoint was used.

## Observed failure and bounded repair

The Android workflow's embedded Server test failed during teardown of
`test_deadline_can_expire_inside_private_gate_but_never_dispatch_afterward`.
The recorded error is `failures == [TimeoutError('timed out')]` from
`engine_server` in `server/tests/test_volume_effects.py`; it escaped the
optional second request read. The production test still expects
`volume_timeout` and exactly one recorded version GET. Its body and assertions
are unchanged. The log alone does not measure the exact host scheduling pause.

Preserved CI log: `/private/tmp/larenor-32d43fd-android-server-failed.log`,
SHA-256 `da9b6ad924749a380975354593a6389907c3ade57d97796083407453383623f8`.
No remote rerun was requested or performed by this task.

After a version exchange the guarded client may legitimately send no second
request, including when its deadline expires in the private gate. The fixture
now catches `socket.timeout` only around that optional second `read`, closes
that accepted stream through its existing context manager, and continues the
listener loop. Partial second headers/bodies are not recorded, acknowledged
or passed to the reply callback. This is fixture lifecycle handling, not a
production retry or acceptance of an incomplete request.

The first request still must be exactly `GET /version HTTP/1.1` with an empty
body. Its timeout, the version hook's timeout and reply callback exceptions
remain visible failures. Header/body limits remain 16,384/4,096 bytes; accepted
socket timeout stays 2 seconds, accept polling 0.05 seconds and join 3 seconds.
The same ownership/close/join/failures checks remain. No blanket exception
swallowing, timeout increase, production dispatch change or global failure
counter reset was introduced.

## Runtime RED and GREEN

- `065816969e83c47eddd7da68091005e5ff7147d8`: three real temporary AF_UNIX
  cases against the unchanged old fixture: empty second request, partial
  header and partial body. Each waits for the existing 2-second timeout and
  verifies one version GET and zero reply callbacks. All three then failed
  the real fixture teardown: **3 FAIL, 6.18s**.
- `67ef74d20e2274b3767af3a9e2783e3dfade8ed3`: the scoped catch above:
  **4 PASS, 6.46s**, including the unchanged original deadline test.
- Expanded first check: **83 PASS, 1 SKIP, 20.73s**. The skip is the existing
  real Linux SO_PEERCRED test on macOS. No new test was skipped.
- Final tests add a successful independent stream after timeout, and nine
  negative cases: wrong first method/body, first timeout, version-hook timeout,
  oversized header/body, malformed length and reply timeout/exception.
  Negative tests join the real worker before owner stop so shutdown cannot
  hide the expected fixture failure. They check its nested error kind and
  that no thread remains alive.

An initial command used a wrong relative destination and did not create the
new test file. This setup failure was corrected before the actual RED run;
it is not counted as a product or fixture runtime failure.

## Stress, related coverage and limits

Four parallel subprocess workers ran eight repetitions, each containing the
three timeout cases plus the original production deadline assertion:
**8 × 4 PASS**. Per-process logs and exit codes are in
`/private/tmp/larenor-volume-fixture-stress.json`; all subprocesses were waited
for and reaped. The 32 repeated executions are not 32 distinct new tests.

Final related set: **612 PASS, 3 SKIP, 54.51s**. The three skips are existing Linux SO_PEERCRED checks on macOS. It covers Engine HTTP, volume plan,
resources, observation/transport, journal, CREATE effects/preparation and
bootstrap helper. These results are separate from the stress and earlier
runs; they are not added to the CI result or counted as a new full Server run.
The local AF_UNIX tests prove this fixture's lifecycle and unchanged dispatch
oracles, not trusted host UID, real Engine CREATE, bootstrap or installation
authority. Python syntax compilation and `git diff --check` passed.

Evidence paths under `/private/tmp/`: `larenor-volume-fixture-red.log`,
`larenor-volume-fixture-green.log`, `larenor-volume-fixture-expanded.log`,
`larenor-volume-fixture-related.log`, `larenor-volume-fixture-stress.json`.
The final source/tree, log hashes, process reaping and unchanged production
checks are in `larenor-volume-fixture-delivery-evidence.json`.
