# F60 launch-key consumer evidence — 2026-10-03

## Defect and scope

Moonlight's provider launch request and its later `Game` connection must use the same remote-input AES key and key ID. The previous integration created key A for `NvHTTP.launchApp`, then upstream `Game` created a new `NvConnection` with key B. The two requests therefore could not be proven to share the same pending-session key. This source-confirmed composition mismatch motivated the repair; the former hosted RTSP failure is not attributed solely to it without changed-source provider acceptance.

This slice changes only the native consumer handoff. It does not put a key, key ID, provider address, certificate, or launch credential into an Intent, MethodChannel DTO, operation journal, file, receipt, diagnostic, or log.

## Source-locked producer contract

- Engine revision: `moonlight-android-12.2-larenor-embed-v5`
- Upstream revision: `b48494cb96bff23d8886c4775cc4f39a1075495d`
- Reviewed downstream patch SHA-256: `2453816189554e3f1d78b79457830b5b80bf6686a32ee686201ab5b9dcb941f8`
- Candidate AAR SHA-256: `ec3e8fc3023848046e38e2ceefcb482a15e9c91895e5a247de47e6a0c6d759a5`
- Candidate receipt SHA-256: `2000bb39fddac16f9027fae62732767d2d277ff786cad47f6c552737a1d348db`

The package verifier requires the protected `Game.createConnection(...)` factory and the public `NvConnection(..., byte[], int)` constructor. The constructor clones the 16-byte key and accepts only key IDs in `0..Int.MAX_VALUE`; it exposes no getter.

## Consumer ownership and lifecycle

After an exact `currentGameMatched` launch readback, the runtime retains one process-private key lease. Its owner binds the current native binding ID and revision, authority fingerprint, Core session ID and revision, host/pairing/catalog/app revisions, selected-quality fingerprint, upstream host and app, provider address and ports, Moonlight unique ID, and server-certificate fingerprint.

The process store first activates the current native binding and creates an opaque launch reservation before provider I/O. Provider success may publish through that exact reservation only while the same binding remains active. The runtime also rechecks its generation and complete bound session under its own lock before the reservation commit. A successor binding invalidates the old reservation, so a late old provider completion cannot overwrite or retire the successor key.

The foreground launch token is attached atomically to that owner. `LarenorMoonlightGame.createConnection` consumes the exact token once and passes the same launch key and ID to the v5 constructor. Ownership transfers out of the material under its lock before caller code runs, so a concurrent second caller cannot observe the array. The transferred array is wiped directly when the constructor returns or throws. The stored copy is also wiped on expiry, rejected token issuance, exact binding/session/authority retirement, replacement launch, activity destruction, or runtime close. A stale runtime, mismatched owner, or foreign activity token cannot consume or retire a successor binding's key.

If the selected provider app is already running, the pinned Moonlight contract supports a non-destructive `resume` request. `NvHTTP.launchApp(context, "resume", ...)` sends the fresh RI key and key ID and accepts only a nonzero provider `resume` result. The runtime therefore performs that provider-confirmed resume without quitting or relaunching the matching app, then retains the exact acknowledged key for `Game`. A different running app still follows the existing quit-then-launch path.

## Verification boundary

Focused tests cover A/A handoff versus the former A/B mismatch, matching-app resume versus new/different-app launch plans, atomic one-use consumption under concurrent callers, caller-array wiping, late old provider completion after successor activation, binding and session successor fences, foreign tokens, issue failure, expiry, and lifecycle retirement. Runtime reflection binds the v5 protected factory, 9-argument constructor, and actual `NvHTTP.launchApp(ConnectionContext, String, int, boolean)` contract.

Root mounted the independently verified v5 AAR and passed 55 Moonlight JVM tests (47 runtime + 8 launch-key), zero errors/failures/skips, within the 146-test composed gate. Actual AndroidTest Kotlin compilation passed (315 Gradle tasks). [Composed evidence](f60-launch-key-composed-2026-10-03.md) records the frozen-source and private-log hashes. These checks prove consumer/package compatibility and bounded key ownership; the existing strict owned-Sunshine acceptance remains the real provider gate.
