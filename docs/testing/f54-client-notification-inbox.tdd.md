# F54 Client notification inbox acceptance

This slice connects the Android Client to the authenticated, pull-only Core
notification contract without Google Mobile Services or a second notification
service.

| Acceptance | Production evidence | Automated evidence |
| --- | --- | --- |
| Private previews stay private | The tablet grid renders only `publicProjection`; a private event must carry the fixed redacted projection and its full content is shown only inside an explicit in-app detail action. The UI labels this slice as an in-app inbox and does not claim Android background delivery or lock-screen permission. | Model tests reject a private event with an unredacted or altered projection. Widget tests assert that secret title/body text never enters the grid or semantics tree. |
| Reconnect is deterministic and replay-safe | A cryptographically random registration ID is stored in secure storage per Core, home, and account. Registration is replayed with the exact stored expiry, writes use compare-and-swap, pages require strictly increasing unique sequence/ID values, and conflicting duplicate envelopes fail closed. | Store tests cover scope binding, CAS, and a late lifecycle callback. API/model tests cover authenticated register/pull/ack, delayed response rejection, duplicate/out-of-order/replay rejection, and exact subscription revision. |
| Interaction authority is current | Pull and acknowledgement bind the verified Core session, account generation, interaction epoch, route owner, window lifecycle, subscription revision, and the exact event object. A late response cannot update state or navigate. Targets are relative, query-free, and allowlisted; acknowledgement succeeds before navigation. | Adapter tests use a delayed response barrier. Widget tests exercise keyboard activation and TalkBack semantics in EN/TR at 600 and 1200 logical pixels with 2x text scale. |

## Deliberately open acceptance

The Android platform notification channel, runtime permission prompt,
foreground/background delivery engine, lock-screen rendering, process death,
Huawei/OEM power behavior, and physical-device delivery are the next F54 slice.
This software-only inbox does not close F54 or its manual device gate; progress
therefore remains **17/125** and feature completion remains **0/63**.
