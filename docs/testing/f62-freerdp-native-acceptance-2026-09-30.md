# F62 FreeRDP native acceptance evidence

The exact workflow run
[36762392915](https://github.com/ersingundem/larenor/actions/runs/36762392915)
at revision `0513c8414da1cc0431b6182c2619a4edf535900b` built and receipted
both Android ABIs, compiled each receipted runtime into the Larenor APK, and
started the owned x86_64 FreeRDP NLA shadow host. The x86_64 instrumentation
test did not start: the emulator was explicitly launched without VM
acceleration, remained offline or without `sys.boot_completed`, and reached
the unchanged 300-second boot deadline.

The failure is confined to hosted-runner setup. The pinned
`ReactiveCircus/android-emulator-runner` documentation requires KVM permission
before a Linux hardware-accelerated emulator. The repository's established
Android E2E lane already proves the matching hosted-runner contract. The F62
workflow now applies that same bounded preflight only for x86_64: `/dev/kvm`
must be a character device, the disposable runner grants mode `0666`, and
read/write access must verify before the pinned emulator runs with Linux VM
acceleration enabled. Missing or inaccessible KVM fails the workflow instead
of falling back to an unbounded software emulator. The emulator build and
boot timeout remain pinned and unchanged.

This repair does not establish a FreeRDP client connection by itself. F62
requires a new exact workflow run to prove the packaged Android client reaches
the owned NLA host. Physical Windows, RD Gateway, audio, IME, and DeX behavior
remain manual device/provider evidence and no household endpoint was contacted.

## Exact second host result and command-context repair

[Run 36765836443](https://github.com/ersingundem/larenor/actions/runs/36765836443)
at `b76558c4ee09b3f8e5fad4b274ac699576e71821` passed both native package/APK
lanes, owned NLA host startup, and the new KVM preflight. The emulator booted
in 29 seconds. Instrumentation still did not start: the action ran each script
line in a separate `/usr/bin/sh -c`, so `cd android` did not persist for the next
`./gradlew` line, which failed with exit 127. This is an observed command-context
defect, not another emulator boot failure.

The [pinned action source](https://github.com/ReactiveCircus/android-emulator-runner/blob/a421e43855164a8197daf9d8d40fe71c6996bb0d/src/main.ts)
is kept unchanged. It now receives one command,
`python3 tool/f62_packaged_acceptance.py`. That owned runner uses an argv list,
sets the Android working directory on the subprocess itself, bounds the test to
20 minutes and maps timeout/process-start failures to static errors without
printing its disposable password. It deletes only old `TEST-*.xml` outputs from
the fixed ignored report directory before launch. A receipt requires exactly one
new report, exactly the named production class/method and one executed test with
zero skips/failures/errors. The report and receipt are archived with the package.

The prior slice's twelve workflow/package/receipt policy tests passed locally. They prove the
execution and evidence policy, not RDP interoperability. A new exact hosted run
must execute the packaged native client and pass; no timeout was increased and
no TLS/NLA/frame/input/retirement assertions were relaxed.

## Fresh-checkout launcher and owned-host package binding

A subsequent readiness audit found that `tool/f62_packaged_acceptance.py`
still invoked `./gradlew`. That script and its wrapper JAR are intentionally
ignored and are absent from a fresh checkout. An earlier Flutter APK build may
materialize them as a side effect, but the real instrumentation receipt must not
depend on that undocumented prior-task residue.

F61 and F62 now share `tool/android_acceptance_gradle.py`. It copies the wrapper
JAR from the workflow's pinned Flutter SDK beside the repository's tracked
`gradle-wrapper.properties` inside a private temporary directory, applies mode
`0600`, and invokes `GradleWrapperMain` directly. Missing or symlinked wrapper
artifacts and properties fail closed. Process-start and timeout errors remain
static so the disposable RDP password in Gradle argv is never printed.

The owned NLA server is a separate distribution component from the immutable
FreeRDP 3.31.1 Android client source. The workflow now resolves the official
Ubuntu candidate versions for `freerdp3-shadow-x11` and `winpr3-utils`, installs
those exact versions, verifies both with `dpkg-query`, and records both bounded
version strings in the one-test/no-skip client receipt. It does not describe the
distribution shadow server as the 3.31.1 Android engine.

Twenty focused package/workflow/receipt tests passed after this repair. The
materialized launcher started real Gradle 9.7.1, and the native RDP unit batch
passed 14 tests with zero skips, failures or errors. These local gates still do
not establish emulator-to-NLA interoperability; only a new terminal hosted run
with the strict instrumentation XML and receipt can do that.

## Private launcher and canonical public receipt boundary

The acceptance launcher now requires the Android project to be an absolute,
existing directory whose resolved path is byte-for-byte the supplied path. Its
temporary workspace must be an absolute absent child of a direct real
directory. The launcher resolves the Java and Flutter executables, rejects
symlinked project, executable, wrapper and properties boundaries, creates each
private workspace directory with mode `0700`, and creates the copied wrapper
files exclusively with mode `0600`. Existing destination files and symlinked
destination parents fail closed.

The x86_64 lane is the only artifact-producing lane. After exactly one fresh
named instrumentation XML reports one executed test and no skip, failure or
error, the runner writes one canonical JSON receipt. It binds the real Git HEAD
(and the exact `GITHUB_SHA` when present), SHA-256 of the immutable packaged
FreeRDP receipt, and the exact owned shadow-host package versions. The private
raw JUnit file is removed before the workflow uploads only that public receipt;
the native package, disposable credential and device report are not artifacts.

Thirteen focused launcher/workflow/receipt policy tests pass for this boundary,
including relative paths, symlinked project ancestors, symlinked destination
parents, exclusive destination creation, canonical receipt serialization and
raw-report removal. This policy evidence does not claim native RDP
interoperability. A terminal hosted run must still execute and receipt the real
instrumentation test.
