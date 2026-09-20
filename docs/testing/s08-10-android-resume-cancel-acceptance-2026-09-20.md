# S08.10 Android resume and cancel acceptance

Status: implementation complete; physical Android SAF verification remains open. Queue progress stays **17/125** and feature progress stays **0/63**.

| Acceptance | Production evidence | Automated evidence |
| --- | --- | --- |
| A memory-only interruption can resume only within the exact Core, home, resource, ACL, user, service descriptor, endpoint, session, route and lifecycle authority. | `CoreBoundedInterruptedDownload` is API-created, immutable and redacted. Only complete authenticated frame payloads are retained. Resume uses a new request ID with the prior receipt ID and exact byte offset; changed metadata and stale controller authority fail closed. | `bounded_download_test.dart` rejects offset, trace, digest, MIME and full-length drift and verifies prefix plus suffix hashing. `core_bounded_download_controller_test.dart` verifies revision/lifecycle retirement. |
| Resume and Cancel are explicit, verified operations. | Cancel sends a bodyless `DELETE` for the active request before retiring the local transport. Resume is enabled only after an exact interrupted receipt readback. Completion is not accepted until the new completed receipt, full length, SHA-256, MIME and service revision match; SAF sees bytes only afterwards. | API tests cover idempotent cancel replay and partial-frame discard. Controller tests cover exact cancel/readback, delete/readback failure and one final SAF publication. |
| Tablet and DeX interaction remains accessible and localized. | The existing resource row exposes 48dp Resume and Cancel actions, keeps stored/reachable/provider/device evidence distinct, and announces transfer state through the existing live-region trust card. | Widget tests cover EN/TR at 600/1200 width and 2x text, TalkBack button labels, Enter activation, 48dp targets and restoration of Resume after verified cancellation. |

The remaining physical gate is a real Android document-provider run that confirms the fully verified bytes are handed to SAF on representative Huawei tablet and DeX hardware. No partial bytes are persisted or published before that gate.
