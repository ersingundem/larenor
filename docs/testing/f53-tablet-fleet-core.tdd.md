# F53 managed tablet Core foundation

21 September 2026. This software-only slice establishes the Core authority for
Larenor tablets. It does not claim Android Device Owner provisioning or a
physical Huawei/DeX acceptance result.

## Three software acceptance criteria

| Criterion | Evidence |
| --- | --- |
| Registered identity, last-seen time, profile state and the closed capability set survive restart as read-only state bound to the exact Core, home, owner and login-device family | `test_registered_identity_last_seen_and_capabilities_are_read_only_state`, `test_registration_profile_heartbeat_and_restart_are_exact`, `test_scope_session_role_and_revocation_fail_closed` |
| Only an owner tablet session may heartbeat/poll/complete and only an administrator may list, change policy, revoke, issue or read the bounded secret-free HMAC audit; audit or storage tampering blocks reads and restart | `test_owner_admin_authority_and_tamper_evident_audit_fail_closed`, `test_scope_session_role_and_revocation_fail_closed`, `test_tampered_device_or_command_blocks_reads_and_restart` |
| Every command is gated before delivery by the exact device and policy revisions, capability, a five-minute maximum expiry and a byte-exact idempotency key; expiry or lost acknowledgements never cause an automatic replay | `test_command_policy_revision_expiry_and_idempotency_gate_before_delivery`, `test_command_delivery_is_bounded_replay_safe_and_capability_aware` |

The API accepts four closed command kinds and no arbitrary shell, URL, intent,
package name or payload. Device registration is limited to 256 records and the
command journal to 10,000 records and the audit journal to 20,000 records.
Revocation immediately blocks heartbeat, poll and completion. An authenticated
administrator may list devices, advance a desired profile revision, revoke a
record, issue commands and read audit events; the exact registered session
family is the only reporter for that tablet.

## Verification

The RED `test(tablet-fleet): define Core policy gates` commit failed all three
new acceptance tests because the Core route did not exist. The focused GREEN
gate passes **7/7 tests** across
the tablet registry and policy suite. Python compilation, repository security
policy, execution queue validation, progress policy, secret scan and diff checks
are the PR gates.

Physical Device Owner provisioning, OEM kiosk controls and a real Huawei/DeX
device remain manual acceptance. This slice exposes no MDM enrollment claim and
does not execute device commands inside Core.
