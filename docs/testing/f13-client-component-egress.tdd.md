# F13 Client component-egress boundary TDD evidence

Date: 2026-09-23

This slice makes the existing Core outbound-policy contract usable from the
Android Client without granting the Client a general network proxy. F13 stays
pending and neither progress counter changes.

## Three guarantees

1. **Strict, redacted records.** The Client accepts only schema v2 policy,
   grant, pinned-address and audit records with exact keys, closed enums,
   bounded lists and valid attribution tuples. Service IDs, service revisions,
   policy revisions and address network classes must agree. Public diagnostic
   strings contain no host, address or actor data.
2. **Exact-revision writes.** Reads and replacements are restricted to Home
   Assistant, Proxmox and Keenetic components. Every replacement carries both
   the displayed policy revision and the selected service revision. The
   returned policy must belong to that exact service/component, advance once
   and contain exactly the requested grant. Unsupported service kinds make no
   request.
3. **Route and account authority.** The controller owns one selected service,
   drops late results after route retirement or logout, serializes operations
   and never retries an uncertain mutation. A conflict or transport failure
   clears the stale policy and requires a fresh authoritative read.

## RED to GREEN evidence

The RED checkpoint `fef5f6ce` specified the missing typed model, exact API and
authority-safe controller and failed because those production modules did not
exist. The GREEN implementation passes the five focused contract and lifecycle
tests plus the Core-parity address classification regression and targeted
static analysis.

```text
flutter test test/features/server/server_component_egress_test.dart
00:00 +6: All tests passed!

flutter analyze lib/features/server/component_egress \
  test/features/server/server_component_egress_test.dart
No issues found!
```

## Remaining F13 gates

The administrator tablet screen, explicit DNS resolution/review flow and
physical LAN/public reachability acceptance remain later slices. Core remains
the authority that resolves and validates pins before a worker can connect.
