# K09 controlled app view production gate (2026-09-30)

## Production boundary

The shipped Kiosk screen opens `KioskControlledViewScreen`. The operator must
confirm one app-surface session before it can publish. The screen captures only
the marked `RepaintBoundary`; it does not request Android MediaProjection and
shows full-device projection as unavailable. Flutter documents that
`RenderRepaintBoundary.toImage` is valid only after the boundary has painted:
<https://api.flutter.dev/flutter/rendering/RenderRepaintBoundary/toImage.html>.
Android separately requires user consent for every MediaProjection session:
<https://developer.android.com/media/grow/media-projection>.

The software gate creates a real managed-tablet record and read-only pairing in
the normal Core, signs the production Flutter account client into that Core over
TCP, and lets `CoreManagedTabletAuthority` validate the exact Core, home,
account, device, pairing revision, token, and discovery document. It then uses
the production MQTT 3.1.1 client against an owned TLS peer. The peer records
bytes before sending QoS 1 PUBACK. The OASIS MQTT 3.1.1 specification requires a
QoS 1 publication to remain unacknowledged until its corresponding PUBACK:
<https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.pdf>.

The acceptance asserts:

- the production Kiosk route is opened and the MediaProjection limitation is
  visible;
- local operator confirmation is required;
- the exact Core-issued MQTT client id, pairing id, and token authenticate the
  TLS session;
- an `active` receipt and a real PNG from the app-surface boundary are
  non-retained, share one request id, and remain at or below 393216 bytes;
- sampling advances through the one-frame-per-second boundary;
- navigating back publishes the matching `retired` receipt before the route is
  removed, and no later frame is published;
- lifecycle retirement disconnects the channel, removing the binding prevents
  reconnect, and no kiosk-policy write occurs;
- a disconnect rejects a pending unacknowledged publication, detaches the old
  channel generation, and rejects replay on that retired channel.
- a TLS connection held before CONNACK retires promptly; its late handshake
  cannot install listeners or disconnect the authenticated successor channel.

## Root independent evidence

```text
server/.venv/bin/python server/tests/support/k09_flutter_acceptance.py
1 passed

flutter test --no-pub test/features/kiosk_remote/mqtt_local_broker_live_test.dart test/features/kiosk_remote/managed_tablet_runtime_owner_test.dart test/features/kiosk/kiosk_remote_view_foundation_test.dart
25 passed

flutter analyze --no-pub
No issues found
```

The gate uses a disposable Core database, a loopback TLS MQTT peer, and an owned
read-only native telemetry source. It sends no household command. Physical
tablet rendering, OEM lifecycle behavior, and a deployed broker remain manual
device checks. Full-device MediaProjection remains explicitly unsupported.
