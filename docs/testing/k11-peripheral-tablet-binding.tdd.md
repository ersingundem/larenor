# K11 peripheral tablet binding

Status: **tablet management and review boundary ready; K11 remains pending**

This is a dependent slice stacked on PR #312's K11 contract. It adds no
peripheral worker and claims no physical Android adapter.

## Three acceptance criteria

1. **Honest provider management.** Settings > Display exposes a common
   Cupertino tablet surface for QR, NFC, BLE, USB, TTS and print in EN/TR.
   Each provider has a separate persisted opt-in choice and independently
   visible support, permission, GMS and connection state. Opt-in alone never grants permission
   or reports an unavailable adapter ready. The native MethodChannel currently
   reports all six adapters unavailable; unexpected native ready claims are
   downgraded to unavailable until a verified worker exists.
2. **Explicit review-only consumption.** Only a ready input provider with a
   trusted authority can show “Review next input”. It fetches a single envelope
   only after a user tap, applies the K11 strict input gate, and renders plain
   text for review. TTS/print and unsupported providers cannot consume. No
   command, WebPanel JavaScript, speech or print operation is dispatched.
3. **Tablet and session safety.** 600/1200 logical pixel layouts with 2x text
   are exercised in English and Turkish. Buttons have 48dp minimum targets and
   readable semantics. Pending input is rejected after route disposal,
   foreground/interaction loss or route cover; reviewed text is retired before
   the route returns. Duplicate events remain rejected by the K11 gate.

## Verification

- RED checkpoint: screen/widget test preceded production implementation.
- Flutter focused widget tests: 11 passed.
- Flutter Kiosk suite: 66 passed. Focused analyzer: zero issues.
- Native Kiosk unit suite: 27 passed, zero failures or errors.
- Security, queue, progress, diff and gitleaks checks are recorded in the PR
  evidence after the final run.

K03.remaining and K08 need their own completion/CI before the K11 bridge can
be connected to real hardware. Real GMS-free Huawei, runtime permission dialogs,
USB cable removal, keyboard-mode reader, NFC/BLE/QR, TTS and print behavior
remain **MANUAL**. Progress remains **22/125** and **0/63**.
