# F34 printable inventory label Client integration

23 September 2026. This slice connects the existing secret-free Android QR
share bridge to the tablet inventory detail screen. It does not count F34 as
complete; exact-head CI and a real Client-to-Core acceptance journey remain.

## Three delivered contracts

1. A verified inventory item can recreate only its canonical scoped QR. The
   printable SVG cannot receive the item label, document references, grants,
   account token or a private file path.
2. One route-owned share controller obtains a fresh native lifecycle/focus
   epoch for every explicit tap. Home, account, route or window authority loss
   retires an in-flight activation before Android can receive the file.
3. The 600/1200 dp tablet detail presents one localized, accessible 48 dp
   printable-label action. Busy, stale and unavailable states are visible and
   the existing manual-entry and camera paths remain available.

## Verification

- `flutter test test/features/inventory test/integration_support/synthetic_core_inventory_test.dart`: **29/29 PASS**
- `flutter analyze lib/features/inventory test/features/inventory`: **No issues found**
- security policy, execution queue validation and `git diff --check`: **PASS**

F34 remains **pending** at **26/125 (20.8%)** and selected feature completion
remains **0/63**. Physical QR camera/share validation stays in the MANUAL
matrix and is separate from the software acceptance gate.
