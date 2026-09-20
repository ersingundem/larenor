# F53 managed tablet Client acceptance

21 September 2026. This Android Client slice consumes the versioned tablet
fleet authority introduced by the Core foundation. It does not provision
Android Device Owner, execute privileged native commands or claim a physical
Huawei/DeX result.

## Acceptance matrix

| Criterion | Production boundary | Automated evidence |
| --- | --- | --- |
| Every record and callback remains bound to the exact Core, home, account generation, endpoint and authenticated session family | Closed `ManagedTablet`/list decoders validate the response scope; both controllers capture account, endpoint and Core/home authority and retire on account, route, visibility or lifecycle change | `records are closed, scope-bound and capability proof is exact`; `late list and malformed authority are discarded fail-closed` |
| Registration, listing, heartbeat, profile and revocation distinguish standard mode from server-proven Device Owner capability | Client registration exposes standard mode only; owner-only actions render only for a Core record with the exact owner capability set; profile and revoke mutations require a fresh list readback | `register heartbeat profile revoke and issue require exact readback`; four `tablet admin remains accessible … with 2x text` cases |
| Poll, command and result handling is bounded, idempotent and fail-closed | Command issue and completion use a stable request/receipt readback; poll pages reject duplicate or unordered IDs/sequences; memory state never executes native work and drops conflicting, malformed or late results | `poll and completion merge replays and verify exact completion receipt`; `malformed and out-of-order command pages fail closed`; `malformed command readback blocks mutations until refresh` |

The administrator screen uses the shared Cupertino service shell and settings
sections. EN/TR tests cover 600 and 1280 logical-pixel windows at 2x text,
48dp actions, keyboard Enter, TalkBack activation and a live status region.

## Remaining manual gate

F53 stays open in the execution queue. Device Owner enrollment, Huawei OEM
power behavior, physical tablet heartbeat, kiosk enforcement and DeX window
acceptance require a provisioned Android device. Until that evidence exists,
Larenor reports only Core-proven capabilities and returns `unsupported` for
work the native client cannot prove it performed.
