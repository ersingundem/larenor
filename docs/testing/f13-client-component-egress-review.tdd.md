# F13 Client DNS review receipt TDD evidence

Date: 2026-09-23

This stacked Client slice consumes the bounded Core resolution contract from
PR #377. F13 and both progress counters remain pending until the stack merges
and real LAN acceptance is recorded.

## Three guarantees

1. **Strict exact-service receipt.** The Client sends only the selected service
   revision and accepts only a schema-v1 receipt whose service, revision,
   component, scheme, host and effective port match the displayed connection.
   Candidate addresses reuse the strict Core-parity LAN/public parser and all
   diagnostic strings remain redacted.
2. **Retired transient state.** The controller never persists resolution
   receipts. A policy reload, account/route retirement, late response or any
   policy write clears the receipt. Resolution is read-like: failure never
   retries or claims a policy change.
3. **Visible review before grant.** The tablet editor opens read-only. Saving
   addresses requires an explicit **Resolve and review** action and an exact
   match between the visible pins and the current receipt. Editing even one pin
   requires another review; blocking all access remains an explicit independent
   action. English and Turkish tablet controls keep the existing scroll and 2x
   text behavior.

## RED to GREEN evidence

The RED checkpoint `a2378aea` adds strict receipt/API tests and late controller retirement
before the model, endpoint call and controller state existed. GREEN passes the
combined domain, API, lifecycle and tablet widget matrix.

```text
flutter test test/features/server/server_component_egress_test.dart \
  test/features/server/server_component_egress_screen_test.dart
00:01 +13: All tests passed!
```

## Remaining F13 gates

The Core and Client PR stack must merge in dependency order. Final completion
still requires Home Assistant, Proxmox and Keenetic resolution/rebinding checks
against real services on the target LAN.
