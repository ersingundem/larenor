# F62 RDP composed-text input

This three-part slice connects the existing FreeRDP UTF-8 IME capability to the
Android Client. F62 stays pending because a real Windows/NLA target and physical
Huawei/DeX acceptance remain separate gates.

## Accepted software boundary

1. The Android bridge accepts one exact owned `ime` input shape and routes it
   through the same monotonic sequence as pointer, physical-key and resize
   events. Empty, NUL-bearing, malformed UTF-16 or over-4096-byte UTF-8 values
   fail closed. Public diagnostics redact the text.
2. The Dart capability contract exposes IME separately. The Client sends text
   only when the exact native engine advertises support, the RDP session is
   connected and the current route/window/lifecycle authority still holds.
3. The connected EN/TR tablet surface provides a keyboard-reachable composed
   text field and 48 dp send action at 600 and 1280 logical pixels with 200%
   text. The in-memory draft is cleared after send, disconnect or retirement.

## Evidence

- Flutter RDP model, MethodChannel, controller and tablet panel package: 20/20.
- Android native contract and FreeRDP engine package: 11/11.
- Scoped Flutter analysis, execution-queue validation, per-commit progress and
  diff checks are required on the exact pull-request head.

No text is persisted, logged, placed in Core, or copied through the disabled
clipboard channel. Physical Turkish dead-key, Huawei soft-keyboard and Samsung
DeX keyboard behavior remain in the manual F62 device matrix.
