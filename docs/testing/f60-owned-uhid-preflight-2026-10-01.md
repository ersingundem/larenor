# F60 owned UHID preflight diagnostic — 2026-10-01

## Observed boundary

GitHub Actions run `36801361054` at its recorded source revision stopped in the
`Require exact hosted UHID capability` step before the provider workspace,
Android build, or instrumentation test started. The owner-only private job log exposes only the public static reason
`gamepadHostUnavailable` plus exit status 1 for that failed preflight. The helper deliberately discarded
`modprobe` output, so this run does **not** establish whether the hosted runner
lacked the kernel module, whether the device node was unavailable, or whether
the node/sysfs identity check failed. It produced no provider or feature
acceptance receipt.

The current GitHub Ubuntu 24.04 image documentation identifies an Azure kernel,
and Ubuntu publishes a separate Azure extra-modules package. Those facts do not
prove which kernel packages were present in this particular runner or which
preflight branch failed. No package installation or device bypass is justified
from this run alone.

## Changed-source diagnostic

The preflight remains fail closed and keeps module output private. It now emits
one of four fixed, non-secret reasons:

- `gamepadRunnerUnavailable`: the exact GitHub-hosted Ubuntu runner identity
  gate failed before any device or privilege operation;
- `gamepadDeviceUnavailable`: querying the fixed `/dev/uhid` path failed before
  module loading;
- `gamepadKernelModuleUnavailable`: the fixed, non-interactive
  `/usr/sbin/modprobe uhid` call failed or timed out;
- `gamepadDeviceIdentityUnavailable`: the final fixed character-device and
  sysfs major/minor identity proof failed.

No raw command output, kernel path, host identity, environment value, or device
metadata is published. A future changed-source run is required to select one of
these reasons before any dependency or timing correction can be justified.
The real UHID, exact evdev identity, effective descriptor-bound ACL, BTN_SOUTH
with `SYN_REPORT`, and `SYN_DROPPED` rejection gates remain unchanged.

Primary package/image references used only to bound that conclusion:

- GitHub-hosted Ubuntu 24.04 image inventory:
  <https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md>
- Ubuntu Azure extra-modules package metadata:
  <https://packages.ubuntu.com/noble-updates/linux-modules-extra-azure>

## Local evidence

```text
python3 -m unittest tool.tests.f60_owned_gamepad_test
python3 -m py_compile tool/f60_owned_gamepad.py tool/tests/f60_owned_gamepad_test.py
```

These local checks validate only deterministic classification and fail-closed
behavior. They are not a hosted UHID or Sunshine stream result.

Root verification: 116 related F60/queue/progress tests passed, including a new
regression that module spawn/timeout exceptions cannot expose command data.
No hosted device result is inferred from these checks.
