# F13 component-egress tablet editor TDD evidence

Date: 2026-09-23

This dependent Client slice gives the strict F13 policy boundary a discoverable
administrator surface. F13 and both progress counters remain pending until the
separate Core DNS review and physical network acceptance gates are complete.

## Three guarantees

1. Home Assistant, Proxmox and Keenetic connection cards expose **Network
   access**. Other service types expose no action and issue no policy request.
2. Opening the editor performs only a read. An administrator must explicitly
   save 1–8 unique Core-compatible IPv4/IPv6 pins or explicitly block access.
   Writes carry the displayed service and policy revisions through the strict
   API; uncertain writes disable further changes until refresh.
3. The editor uses the shared Cupertino surface and type scale, contains no
   credential fields, supports scrolling controls at 600 logical pixels and
   2x text, and provides English and Turkish labels with live status output.

## RED to GREEN evidence

The RED checkpoint specifies the supported/unsupported service matrix, exact
save/block request, and two-language tablet layout before the presentation
module and connection-card action existed. GREEN passes the focused widget
matrix, the existing service screen suite and targeted static analysis.

```text
flutter test test/features/server/server_component_egress_screen_test.dart
00:00 +5: All tests passed!
```

## Remaining F13 gates

Core must provide an explicit bounded DNS resolution/review receipt so users do
not have to discover pins manually. The final acceptance also needs real Home
Assistant, Proxmox and Keenetic routes on the target LAN.
