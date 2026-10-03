# F62 Gateway endpoint build diagnostic (2026-10-03)

## Actual failed run

GitHub Actions run `37137081865`, job `111243687742`, tested exact source
`950eda1458fe0fd82d7d31b9186edf10f2cc2edd`. The Gateway/auth build completed and emitted its
closed build receipt. The following FreeRDP endpoint build exited 2 with the existing closed stage
`freerdpBuildFailed`; the transport step was skipped. No public acceptance receipt was produced.

The retained job log is private and bounded at
`/private/tmp/larenor-f62-950-run37137081865/job.log`, SHA-256
`a6ad20824364a3f9de4c6c1cb4c7f4ec8e9c76c2fa892d30c854b6e0f929db90`. It contains neither the
private `configure.log` nor `compile.log`. The workflow deleted both with the disposable workspace,
so the configure-versus-compile cause is not recoverable from this run. The approximately
31-second interval between the Gateway receipt and failure does not identify the failing compiler
input and is not treated as causal proof. A same-SHA rerun is not warranted.

Cleanup then exited 1 independently. The private log contains 14,126 removal failures, all under the
owned `build` subtree. The Go module cache deliberately creates read-only module directories; the
old cleanup used plain `rm -rf` without first restoring owner permissions. This cleanup defect does
not explain the preceding FreeRDP build failure.

## Narrow correction

The private candidate gives each FreeRDP build invocation an explicit `configure` or `compile`
phase. A failure writes one 0600 JSON record before cleanup with only:

```
schemaVersion, runnerSourceRevision, sourceRevision, sourceArchiveSha256,
targetPatchSha256, sourceManifestSha256,
phase, failureCode, exitCode, logSha256, featureAccepted=false
```

`failureCode` is closed to `timeout`, `logTooLarge`, `missingDependency`, `configurationError`,
`missingHeader`, `compilerError`, `linkerError`, `resourceTerminated`, or `commandFailed`. No source
line, compiler message, filesystem path, credential, provider value, or build output is copied into
the record. The SHA binds the private log without publishing it. Successful builds create no
failure record.

The always-run cleanup step copies this closed record to `test-results` when present, then invokes a
new `prepare-cleanup` command. That command walks only the already validated owned workspace,
rejects changed ownership or special files, does not follow symlinks, and restores owner read/write
and directory traversal permission. It does not inspect or publish file contents. The workflow then
removes the disposable root and uploads the closed failure record only on a failed job.

## Evidence and limits

Focused tests exercise every closed classifier, actual failing and successful subprocesses, receipt
privacy and mode, symlink-safe owned cleanup, and workflow ordering. Existing fixture and probe
self-tests remain required.

This candidate diagnoses the next changed-source build without relaxing source, patch, archive,
ELF, NLA, Gateway, RDPDR, or acceptance gates. It does not prove why run `37137081865` failed and
does not mark F62 accepted. Root owns review, Git integration, and any changed-source dispatch.

Root review also binds the full completion-branch SHA in runnerSourceRevision, rejects Boolean exit codes, and removes the focused test's workstation-specific import fallback. No compile cause is inferred from the new diagnostic implementation.

Root validation after composition: 37 focused runner/workflow/archive/diagnostic tests and eight subtests passed; fixture self-test 8/8 and probe self-test 6/6 passed. Scoped Ruff and actionlint were clean. The full source SHA is preserved in the failure record; none of these portable checks establishes real Linux or Android acceptance.

## Exact changed-source result

Run [37138370042](https://github.com/ersingundem/larenor/actions/runs/37138370042), job `111247471578`, tested exact `3f23132ffc4ac151ee2ad3f35fc9e274a3c0e573` and completed failed. The owned Gateway/auth build passed. The closed failure artifact identifies `phase=compile`, `failureCode=compilerError`, and `exitCode=1` for pinned FreeRDP `63b948ca5cb94307fd5444ee6e73927a41ccdab4`; it does not disclose or prove the individual compiler diagnostic. The cleanup step passed, independently confirming the narrow owned-permission repair. Transport and Android effect steps did not run.

The downloaded 0600 receipt is 576 bytes, SHA-256 `ebf04c2cb4488dbb129c294269005db7e16efbbdb79c14d3618aab7ef1be8911`; its private compile-log binding is `87c634cc2137d85f2a6cb055f051f2932b5a53bc890c40a525e7a8c1caeb452c`. Root checked the closed keys, exact runner SHA, pinned archive/patch/manifest identities, and `featureAccepted=false`. Pinned C/API review precedes any changed-source run. This result cannot promote F62 or authorize merge.
