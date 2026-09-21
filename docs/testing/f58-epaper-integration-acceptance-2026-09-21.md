# F58 e-paper mini home screens — integrated software acceptance

The queue remains **22/125** and selected-feature progress remains **0/63**.
This package closes three software criteria without claiming the physical
OpenEPaperLink/tag gate.

## Accepted software criteria

1. **Durable, bounded Core delivery.** Core persists device mappings, current
   shared snapshots, preview records, poll receipts, and verified delivery
   state in a strict SQLite schema. Authenticated HTTP exposes bounded
   render/poll/acknowledgement flows; restart recovery, HMAC tamper checks,
   payload/frame ceilings, and secret-rejecting shared content are covered by
   focused API and service tests.
2. **Explicit administration and fail-closed command authority.** Only an
   authenticated admin can map a display or preview, confirm, and cancel a
   refresh. Every operation binds the exact Core, home, account, session
   family, device, and source revisions. A replay, foreign session, expired
   preview, changed revision, partial ACK, or late callback cannot become a
   verified result. Publishing remains `uncertain` until the physical bridge
   returns an exact complete acknowledgement.
3. **Discoverable tablet management and preview.** The Android Client exposes
   a route from the verified Core home, performs a fresh authority handshake,
   and retires its API/controller on account, Core, home, route, lifecycle,
   focus, or window-authority changes. The mapping form, read-only preview,
   evidence states, refresh confirmation, and server-backed cancellation are
   keyboard/TalkBack reachable with 48 dp targets and were exercised in EN/TR
   at 600 and 1280 logical pixels with 2x text.

## Manual boundary

`MANUAL-F58-HARDWARE` remains open. A supported e-paper tag/access point and
bridge firmware must prove actual radio delivery, refresh latency, battery
telemetry, rotation/orientation behavior, and long-running offline recovery.
Software never reports physical success before that device's exact ACK.
