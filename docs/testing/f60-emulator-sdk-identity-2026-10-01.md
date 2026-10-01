# F60 hosted emulator SDK identity correction (2026-10-01)

Exact `1887ff9a0b19468ff344434863f83e08878e0d18` failed the
[discovery run](https://github.com/ersingundem/larenor/actions/runs/36797303341)
and [stream run](https://github.com/ersingundem/larenor/actions/runs/36797304940)
after the receipted engine and KVM setup. The fixed failure was
`Android emulator identity is unavailable`; the private stream traceback
established `FileNotFoundError` for the bare `emulator` subprocess command.
The emulator action had already launched its SDK executable. Neither failure
establishes a provider workspace, NSD result, terminal Android test count, or
stream receipt.

The shared identity probe now invokes the executable from the configured
`ANDROID_HOME`/`ANDROID_SDK_ROOT` SDK. Both variables must identify the same
absolute SDK if present. Missing configured binaries fail closed instead of
silently selecting another emulator from PATH. PATH discovery is retained only
when no SDK is configured. The child receives PATH and the normalized SDK
variables, without unrelated private environment values.

The root regression runs a real temporary executable in an SDK path containing
spaces with no emulator on PATH. The exact old source raises the observed
`FileNotFoundError` category (RED); the corrected source reads the version
(GREEN). Thirteen discovery tests pass, covering either SDK variable,
conflicting roots, missing executable, relative root, PATH-only discovery,
and exclusion of a private sentinel. This verifies executable resolution,
not emulator boot or Sunshine acceptance. Changed-source hosted execution is
still required.

Primary references:

- [Android emulator command-line documentation](https://developer.android.com/studio/run/emulator-commandline)
  shows the SDK `emulator/emulator` executable path and command-line invocation.
- The [pinned emulator action implementation](https://github.com/ReactiveCircus/android-emulator-runner/blob/a421e43855164a8197daf9d8d40fe71c6996bb0d/src/emulator-manager.ts)
  starts the SDK executable; this is distinct from assuming a bare command is
  available to a later subprocess.
