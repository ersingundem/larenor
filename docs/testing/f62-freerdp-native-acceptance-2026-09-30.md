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
