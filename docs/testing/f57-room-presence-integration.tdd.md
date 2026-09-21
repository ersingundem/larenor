# F57 durable local room presence integration

This integration joins the privacy-bounded Core reducer and Android tablet
surface under one durable Core authority. Exactly three software acceptance
criteria are in scope:

1. **Local evidence remains private and durable.** Only packaged Core code can
   submit bounded Home Assistant, BLE, or UWB observations. No raw signal HTTP
   endpoint exists. Raw identifiers are reduced to SHA-256 replay checkpoints;
   public state exposes only room, confidence, sample count, and last-seen time.
   The bounded device, estimate, calibration, hysteresis, and idempotency state
   is AES-GCM encrypted in SQLite and survives restart.
2. **Calibration uses exact authenticated authority.** Authenticated HTTP binds
   Core, home, account, session family, account/home revisions, Client session,
   route, and route revision in a server-authenticated authority tag. Preview,
   explicit confirmation, exact receipt, and fresh device readback must agree.
   Foreign, tampered, stale, expired, lost, or replay-conflicting results fail
   closed; an exact completed confirmation remains idempotent after restart.
3. **The tablet route is discoverable and route-owned.** Core Home and Settings
   expose the shared Cupertino surface. The route owns and retires its HTTP
   client on account, Core/home, provider-container, interaction, lifecycle,
   focus, window, or navigation drift. English and Turkish work at 600 and 1280
   logical pixels with 200% text, 48 dp actions, keyboard activation, TalkBack
   semantics, and live status announcements.

## TDD and verification evidence

- RED `9e6ac8b6`: restart, encrypted storage, authenticated HTTP, calibration,
  and foreign-authority tests failed because Core had no durable registry.
- GREEN `0782f2d0`: the encrypted repository, signed authority contract, local
  fusion checkpoint restoration, and five HTTP routes passed 18 Server tests.
- Client RED `a2b432ee` defined privacy, confirmation/readback, stale callback,
  and tablet accessibility boundaries.
- Client GREEN `48b35c1f` adds the real HTTP adapter, account gateway, route
  ownership, Core Home/Settings discovery, and passes 17 focused Flutter tests
  plus focused analysis with no findings.

Queue and selected-feature counters remain **21/125** and **0/63**. Real
ESP32/BLE/UWB/Home Assistant sensors, Huawei MatePad/DeX hardware, and physical
room calibration remain explicit manual gates; no physical acceptance is
claimed by this software package.
