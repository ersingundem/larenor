# F54 native notification identifier hardening

This slice hardens the existing Google-services-free Android notification
renderer. It does not add background delivery or claim physical-device
acceptance.

| Acceptance | Production boundary | Automated evidence |
| --- | --- | --- |
| Distinct events stay independent | A persisted, positive native identifier is allocated for each exact 32-byte event ID. Java hash collisions cannot replace another notification or its `PendingIntent`. The mapping remains bounded by the 50-event reconciliation batch. | Robolectric uses two different valid event IDs with the same Java hash and observes two independent notifications and tap event IDs. |
| Restart and cleanup are stable | Reconciliation reuses the stored identifier for the same event after process recreation. Events absent from the authoritative batch have their native notification, tap nonce, and identifier mapping removed. Binding changes clear every owned notification and mapping. | The notification bridge suite covers process restart, high-water replay suppression, stale removal, empty reconciliation, and binding retirement. |
| Tap authority remains exact | A tap resolves its native identifier only through the stored exact event mapping, then retains the existing binding, subscription revision, sequence, and one-use nonce checks. Missing mappings and stale or duplicate taps fail closed. | Native tests consume each colliding event once and assert the exact event IDs delivered to Flutter; existing tests cover stale revision and one-shot nonce behavior. |

F54 remains `pending`: always-on background/Doze/OEM behavior and Huawei/Android
physical acceptance are still manual gates, and F05 remains a dependency. Queue
progress stays **22/125** and selected feature completion stays **0/63**.
