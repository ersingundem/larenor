# Native storage failure diagnostics

This is a diagnostic repair for manual characterization run `34213095299`,
source `5cbff217cdcf719d9162b9b2b33bf22dd47a1996`. Both native jobs failed:
amd64 printed the generic failure after 47.86 seconds and arm64 after 32.18
seconds. Python preparation and dependency consistency checks completed first.
The preserved complete log is 70,095 bytes, SHA-256
`b72781d47c47d8d7c8926cdf91063b3412da353da04571353c1a445ef8514467`.
Neither duration nor `storage_characterization_failed` identifies the failed
daemon, image, bootstrap or application check. The underlying native failure
remains unresolved; this change does not claim that the native fixture passes.

`tool/jellyfin_storage_ci.py` now emits one bounded ASCII stderr line containing
a closed phase and static code on failure. For example:

```text
storage_characterization_failed phase=bootstrap_initialize code=fixture_command_failed
```

The runner marks source capture, daemon startup/cleanup, image and volume journal
preparation, helper staging/build/inspection, bootstrap probes, application
create/start/restart and readback boundaries. An inner failure survives successful
cleanup. A cleanup failure prevents a success receipt and identifies cleanup.
Known existing static errors are allowlisted; unknown errors produce the generic
code. Exception formatting/properties, raw subprocess output, environment,
paths, configuration and credentials are never printed. SIGINT/SIGTERM/alarm
retain the existing cancellation output and owned-process cleanup path.

Successful receipt JSON, actions, dependencies, manual/native guards, source
checks, image and volume primitives, UID/NoCopy checks, timeouts and cleanup
operations remain unchanged. There is no fallback daemon, retry, guard relaxation
or installer/API change. `installAvailable` remains false. Removing only the
new diagnostic wrappers from the AST reproduces 21 existing runner/launcher
functions and classes exactly.

The local checkpoints are:

- `9d1e376`: eight runtime RED cases demonstrated missing phase/code output
  through the actual fixture consumer and CI entry point.
- `e2da1e3`: the same eight cases passed with the minimal diagnostic change.
- `19ab2e0`: seventeen new diagnostic cases plus 122 existing fixture/launcher
  cases passed (139 total, zero skips, 3.59 seconds). Tests cover build text
  redaction, source rejection before daemon start, actual owned-directory
  startup cleanup, cleanup failure, manipulated exceptions, real SQLite journal
  preparation errors, and no mutation replay or success receipt on failure.
  Two incomplete image/volume test doubles initially failed before their intended
  seam; adding the required `pull`/`create` methods corrected test setup. Those
  two failures are not additional product RED evidence.

Validation used the existing Server Python environment from this worktree's
`server/` directory. Commands were `python -m pytest` for the five fixture test
files (diagnostics, CI, smoke, probe and bootstrap helper), branch coverage for
the two changed tool modules, and `python3 -m unittest discover -s tool/tests -p
'*_test.py'`. All 215 dependency-free policy tests passed in 48.065 seconds;
`tool/check_security_policy.py` and `git diff --check` passed. Combined coverage
is 478/495 statements plus 63/68 branches (96.09%); launcher 97.58%, runner
95.67%. Offline fakes and owned synthetic subprocesses were used; no Docker,
daemon, HA/home access, workflow dispatch, push or full Core suite was run.

Private evidence uses `/private/tmp/larenor-jellyfin-diagnostics-` for RED/GREEN,
JUnit, coverage, policy, source-preservation and delivery receipt files. The
original native log is preserved separately as
`/private/tmp/larenor-5cbff21-native-storage.log`. A reviewed future manual native
CI run must provide the next diagnostic evidence before selecting any runtime
fix; physical-home and installation acceptance remain separate.
