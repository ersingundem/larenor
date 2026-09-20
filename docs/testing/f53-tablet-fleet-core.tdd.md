# F53 managed tablet Core foundation

21 September 2026. This software-only slice establishes the Core authority for
Larenor tablets. It does not claim Android Device Owner provisioning or a
physical Huawei/DeX acceptance result.

## Acceptance

| Criterion | Evidence |
| --- | --- |
| Registration, profile revision and heartbeat stay bound to the exact Core, home, account and login-device family | `test_registration_profile_heartbeat_and_restart_are_exact`, `test_scope_session_role_and_revocation_fail_closed` |
| Standard and Device Owner capabilities remain explicit; privileged commands cannot be queued for a standard tablet | `test_command_delivery_is_bounded_replay_safe_and_capability_aware` |
| Command issue, delivery and completion are bounded and idempotent; a lost poll response can be replayed without re-executing or changing the receipt | `test_command_delivery_is_bounded_replay_safe_and_capability_aware` |
| Tablet labels and state are encrypted at rest; command metadata is authenticated and tampering blocks reads and restart | `test_registration_profile_heartbeat_and_restart_are_exact`, `test_tampered_device_or_command_blocks_reads_and_restart` |

The API accepts four closed command kinds and no arbitrary shell, URL, intent,
package name or payload. Device registration is limited to 256 records and the
command journal to 10,000 records. Revocation immediately blocks heartbeat,
poll and completion. An authenticated administrator may list devices, advance a
desired profile revision, revoke a record and issue commands; the exact
registered session family is the only reader and reporter for that tablet.

## Verification

The focused Core gate passed **11/11 tests** across the new tablet fleet and
existing local notification foundation. Python compilation, repository security
policy, execution queue validation and `git diff --check` also passed.
