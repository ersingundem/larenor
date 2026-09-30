# F45 sound event to F54 local notification handoff

Date: 2026-09-30

## Provider contract

Larenor reads only configured Frigate audio review records. Frigate documents that
audio detection produces audio events and that the configured `listen` values are
the exact labels to detect:

- <https://docs.frigate.video/configuration/audio_detectors/>
- <https://docs.frigate.video/integrations/api/review-review-get/>
- <https://docs.frigate.video/integrations/api/get-review-review-review-id-get/>

The source runtime first reads a bounded review list and then reads each exact
review ID. It requires the returned camera and ID to match the authorized source.
The fixture never accepts provider writes.

## Durable handoff contract

- A notification is eligible only when the actor enabled notifications for its
  class before the new event was ingested, the mute has ended, the event is not
  expired or acknowledged, and it is not marked as a false alarm.
- The F45 database inserts the event and a sealed pending outbox row in one
  transaction. The row binds the account, session family, source configuration
  revision, consent revision, and event ID.
- Before the F54 append, Core revalidates the current account/session, Frigate
  read lease, camera/resource authority, and exact F45 source. After the append,
  it revalidates those facts again through the same primary SQLite transaction
  before commit. The source store holds its exact revision stable for the local
  append and receipt update.
- F54 receives a private encrypted local event with the deterministic key
  `sound-event:<event-id>`. A crash after the F54 commit but before the F45
  receipt update retries the same key and reads back the same notification ID
  and sequence. It does not append a second event.
- F45 sets `automationVerified=true` only after validating the exact F54
  notification receipt and sealing its ID and sequence. This means durable local
  inbox acceptance. It does not claim an operating-system alert was displayed
  or seen by a person.
- A stale session/source/consent revision, disabled policy, acknowledgement,
  false alarm, mute, or expiry cancels a pending outbox row without a send.
  Delivered local events are retained under F54's own lifecycle.
- Public F54 projection remains redacted for private notifications. No Frigate
  token, provider response, audio, camera name, or room name is copied into the
  notification payload.

## Evidence

Run from `server/`:

```text
uv run pytest tests/test_f45_f54_notification_handoff.py -q
7 passed

uv run pytest tests/test_f45_sound_events_api.py \
  tests/test_f45_frigate_normal_core.py \
  tests/test_f45_bark_noise_events.py \
  tests/test_local_notifications.py \
  tests/test_f45_f54_notification_handoff.py \
  tests/test_admin_migration.py -q
29 passed
```

The focused acceptance covers normal Core with a real TCP/WS-shaped HA/Frigate
fixture, private F54 pull readback, restart persistence, exact dedupe, a lost
receipt after the F54 commit, session revocation inside the F54 transaction,
camera resource revision drift inside the same transaction, post-ingest source
revision drift, false-alarm cancellation, previous-schema migration, and
authenticated storage tamper rejection. All provider/device
interactions in these tests are local
fixtures; no household device or external notification service is mutated.
