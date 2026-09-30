# F23 Jellyfin Live TV production provider evidence

The normal Core Live TV service uses the administrator's existing authenticated
Jellyfin service connection. The Client setup screen selects that connection,
source type, IANA time zone, and recording quota. It never receives the
Jellyfin token, server-native identifier, or timer identifier.

## Upstream contract

The adapter is pinned to Jellyfin 10.11 and uses the routes implemented by the
official `LiveTvController`:

- `GET /System/Info` and `GET /LiveTv/Info` prove the selected server identity,
  version, and enabled Live TV service before reads and mutations.
- `GET /LiveTv/Programs` and `GET /LiveTv/Timers/Defaults` provide the bounded
  guide and the server-authored timer request.
- `GET /LiveTv/Timers`, `POST /LiveTv/Timers`,
  `GET /LiveTv/Timers/{id}`, and `DELETE /LiveTv/Timers/{id}` implement timer
  creation, reconciliation, readback, and cancellation.
- `GET /LiveTv/Recordings?fields=MediaSources` supplies observed recording bytes, including recordings made outside Larenor. Missing/empty/non-sized sources stay unknown. The fixed `isInProgress=true` query proves cancellation stopped the timer’s active recording.

Primary sources reviewed on 2026-09-30:

- <https://github.com/jellyfin/jellyfin/blob/v10.11.1/Jellyfin.Api/Controllers/LiveTvController.cs>
- <https://github.com/jellyfin/jellyfin/blob/v10.11.1/src/Jellyfin.LiveTv/LiveTvManager.cs>
- <https://jellyfin.org/docs/general/server/live-tv/>

## Authority and recovery behavior

Core persists only the secret-free source snapshot and an HMAC-scoped server
fingerprint. Every guide read, timer mutation, and readback reopens the exact
service revision, requires its authenticated state, verifies the live Jellyfin
identity, and rechecks the service immediately before and after network I/O.
Changing or removing the service makes the source stale and prevents timer
mutation.

Timer creation appends a bounded Larenor request marker to Jellyfin's timer
overview. If the response is lost after Jellyfin commits, Core reports the
request as uncertain. Repeating the same command finds that marker and returns
the existing timer without sending another POST. Cancellation reads the exact
timer before DELETE and succeeds only after an authenticated absence readback.
Restart is permitted only after the old timer is absent or Jellyfin reports an
error, conflict, or cancellation; a still-scheduled or recording timer cannot
be duplicated.

## Storage policy and automatic stopping

The source quota is a Core admission/stop policy. Authenticated Jellyfin recording bytes include retained partial files and recordings created outside Larenor. Admission reserves an explicit conservative 1 MB/second planning budget for the programme duration; this estimate is not measured bitrate. Unknown storage evidence blocks new admission. Snapshot storage is nullable and the Client shows unknown instead of zero.

A normal Core lifecycle dispatcher checks one active recording every five seconds. When observed bytes plus remaining reservations exceed the quota, or storage measurement becomes unavailable, it commits an idempotent cancellation intent before upstream I/O. It cancels the exact timer through the official DELETE route, requires timer absence and absence from the active-recording query, and retains partial byte accounting. A lost cancellation response/restart reconciles the committed intent without duplicating DELETE. A changed/foreign provider never authorizes a safety mutation.

This remote policy can overshoot between observations and during a network outage. A hard filesystem byte cap belongs on the Jellyfin recording volume (operator filesystem/project quota); the API does not enforce that OS cap. Physical disk/tuner acceptance remains manual. The shipped F23 surface is guide and recording management; live viewing uses Jellyfin’s existing playback surface and is not claimed by this guide route.

## Deliberate capability limits

- Core advertises one concurrent tuner. Jellyfin's public API does not expose a
  trustworthy universal tuner-capacity value, so setup never invents a larger
  number.
- A Jellyfin administrator must configure and verify the service connection,
  tuner, guide provider, and recording storage before Larenor setup.
- Guide refresh is explicit through the administrator source setup. There is no
  claimed background scheduler.
- The loopback fixture is an isolated Jellyfin wire-contract fixture. Physical
  tuner reception and long-duration recording storage still require manual
  proof on the user's installation.

## Repeatable gates

```sh
server/.venv/bin/pytest -q \
  server/tests/test_f23_jellyfin_live_tv_normal_core.py \
  server/tests/test_f23_live_tv_api.py
server/.venv/bin/python server/tests/support/f23_flutter_acceptance.py
flutter analyze lib/features/server/live_tv \
  test/features/server/live_tv/server_live_tv_normal_core_test.dart
```

The normal-Core test includes authenticated guide setup, service-revision drift
before mutation, a dropped timer-create response with exactly one upstream POST,
guarded restart, cancellation with absence readback, and secret/native-ID
non-disclosure. The acceptance runner starts normal Core on TCP and drives the
real Flutter Client through source setup, schedule, refresh, and cancel against
the bounded Jellyfin loopback server.

Validation on 2026-09-30: **8 Python tests passed**, including unknown byte evidence and normal Core lifecycle quota cancellation with durable restart/lost-ACK reconciliation; **1 actual Flutter→normal Core TCP→Jellyfin contract acceptance passed**; focused Flutter analyze clean. Full exact HEAD CI and physical tuner/storage proof remain open; no acceptance counter increase.
