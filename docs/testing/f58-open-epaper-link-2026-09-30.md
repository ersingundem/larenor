# F58 OpenEPaperLink production gate — 2026-09-30

## Official source contract

- OpenEPaperLink's Home Assistant integration registers the fixed
  `open_epaper_link.drawcustom` service. Its v1 target is a Home Assistant
  `device_id`; the required request fields are `payload`, `background`,
  `rotate`, `dither`, `ttl` and `dry-run`.
  <https://github.com/OpenEPaperLink/Home_Assistant_Integration/blob/f28c21761365181cfaf203030678f1c29433baf3/custom_components/open_epaper_link/services.yaml>
- The implementation generates an image first. A dry run updates the integration
  image entity and deliberately skips AP/BLE upload; an ordinary request queues
  upload but does not return a physical-pixel acknowledgement.
  <https://github.com/OpenEPaperLink/Home_Assistant_Integration/blob/f28c21761365181cfaf203030678f1c29433baf3/custom_components/open_epaper_link/services.py>
- The tag image entity is JPEG and is keyed to the same Home Assistant device.
  Tag width, height, optional battery, last-seen, pending-update and update-count
  values are separate entities.
  <https://github.com/OpenEPaperLink/Home_Assistant_Integration/blob/f28c21761365181cfaf203030678f1c29433baf3/custom_components/open_epaper_link/image.py>
  <https://github.com/OpenEPaperLink/Home_Assistant_Integration/blob/f28c21761365181cfaf203030678f1c29433baf3/custom_components/open_epaper_link/sensor.py>
- The adapter uses Home Assistant's authenticated REST service and image routes,
  plus the documented device/entity registry WebSocket commands.
  <https://developers.home-assistant.io/docs/api/rest/>
  <https://developers.home-assistant.io/docs/api/websocket/>
  <https://developers.home-assistant.io/docs/device_registry_index/>
  <https://developers.home-assistant.io/docs/core/entity/image/>

## Implemented boundary

- Setup enumerates only authenticated Home Assistant services and joins exact
  OpenEPaperLink device-registry identifiers to enabled integration-owned image,
  width and height entities. The Flutter form selects this proven inventory;
  callers no longer submit a device capability, dimensions, battery, revision or
  bridge reachability claim.
- The renderer emits only two bounded literal text elements in black on white.
  It accepts no template, entity expression, remote URL, local path, font path,
  image download, arbitrary draw type or caller-provided color capability.
- Preview invokes `drawcustom` with `dry-run=true`, then reads the exact image
  entity through Home Assistant's authenticated image proxy. Core bounds the
  JPEG, validates its JPEG marker structure, scan presence and exact observed
  dimensions, stores it with SHA-256 integrity evidence, and serves it through
  an account-bound, no-store artifact route. The Flutter confirmation dialog
  displays those exact bytes. Core does not claim a full pixel decode; malformed
  or header-only input is rejected, and Flutter's image codec performs the
  client display decode.
- Confirmation persists `dispatching` before the single non-dry-run request.
  It revalidates actor, session family, current home revision, authenticated
  service revision, mapping revision and the live registry/device observation
  both before that transition and again before the transport's guarded send.
  A crash, timeout or lost response after `dispatching` becomes durable
  `uncertain`; replay returns the stored receipt and never sends again.
- A matching post-send HA image digest is `readback_observed`: it proves the
  integration's current image bytes, not physical delivery. Every public receipt
  keeps `physicalDeliveryVerified=false` and every device keeps
  `verifiedDigest=null`.
- The schema-2 migration creates the provider command/artifact table in the same
  transaction, preserves authenticated schema-1 mappings and foreign keys, and
  validates every command seal and artifact digest at startup.

## Evidence

```text
server/.venv/bin/pytest -q \
  server/tests/test_f58_epaper_snapshot_core.py \
  server/tests/test_f58_epaper_http.py \
  server/tests/test_f58_oepl_normal_core.py

flutter test test/features/epaper
flutter analyze lib/features/epaper test/features/epaper
server/.venv/bin/python server/tests/support/f58_flutter_acceptance.py
```

The isolated acceptance runner starts normal `create_app`, provisions an
authenticated Home Assistant service, runs the production Flutter client over
TCP, uses real WebSocket registry frames and REST state/service/image routes,
and asserts exactly one dry run plus one physical-send attempt.


Root review additionally binds artifact download to the original session family,
authenticated preview seal, current home/service/mapping authority and cancelled
state. A second session of the same account cannot read that preview artifact.
The focused Server suite was rerun after this fix: 10 passed.
