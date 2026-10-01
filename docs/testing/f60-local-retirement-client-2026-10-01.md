# F60 local retirement Client contract — 2026-10-01

## User-visible effect

The existing v2 revocation terminal state is `local_cleared`. In the Client it
means that Core access for the selected host was retired and the exact private
Moonlight registration on this tablet was removed with causal native readback.
It does not mean that Sunshine removed the paired client from the computer.

The settings confirmation now names both sides of that boundary before the
destructive action:

- Larenor Core access and this tablet's private registration are removed;
- the Sunshine pairing remains; and
- revoking the computer's trust requires removing this client separately in
  Sunshine settings.

After `local_cleared`, a second visible confirmation repeats that the local
retirement completed and that the Sunshine pairing remains. An `unknown`
result continues to use the durable quarantine path. The Client does not
silently retry, relabel an unknown receipt as success, or restore a retired
Core host.

## Authority and recovery boundary

The operation keeps the existing exact account, family, host, pairing and
catalog revisions plus the current Settings PIN, route, lifecycle, idle and
interaction authority. Core retires the host before the native local cleanup.
The Client persists the revocation operation before native I/O and only clears
that recovery record after Core returns `local_cleared` with the native causal
readback revision and receipt digest. Lost acknowledgements are reconciled
from the native journal and never redispatched.

No Sunshine administrator username, password, cookie, client UUID, provider
address, certificate or key is collected by this flow or crosses Flutter/Core.
The current Moonlight registration does not expose a trustworthy mapping from
the public Core host identity to Sunshine's administrative paired-client UUID,
so the Client cannot safely select and remove a provider-side client.

## Provider-side removal remains separate

Pinned Moonlight's `NvHTTP.unpair()` calls the GameStream `GET /unpair` route.
Pinned Sunshine does not implement that route. Sunshine exposes paired-client
removal through its separately authenticated configuration API
`POST /api/clients/unpair`, keyed by the provider's client UUID. The current
local-retirement action therefore does not call that administrative endpoint
and does not claim provider revocation.

If provider-side removal is added later, it requires a distinct administrator
setup and action: private credential collection, exact TLS/provider identity,
an explicit paired-client UUID mapping, current administrator and Settings PIN
authority, a one-use durable dispatch grant, and provider readback. It must not
reuse `local_cleared` or silently change the meaning of “Remove from this
tablet.” Until that separate capability exists, the usable path is to retire
Larenor/tablet access here and remove the client in Sunshine settings when the
computer's trust must also be revoked.

## Validation

The focused Client checks for this slice are:

```text
flutter test test/features/game_streaming/game_stream_settings_screen_test.dart
flutter analyze \
  lib/features/game_streaming/presentation/game_stream_settings_screen.dart \
  test/features/game_streaming/game_stream_settings_screen_test.dart
```

The native/Core owned-host gate must separately prove that `local_cleared`
removes the exact local mapping while the exact Sunshine pairing remains
present. That partial receipt is named `streamAndLocalRetirement`; it is not
provider-pairing-removal evidence. Playback/input/unexpected-disconnect and broad commit CI gates still remain; automatic provider-admin deletion is outside the current product action.

## Primary sources

- Sunshine authenticated client-removal route:
  <https://github.com/LizardByte/Sunshine/blob/v2026.914.233613/src/confighttp.cpp>
- Sunshine GameStream routes:
  <https://github.com/LizardByte/Sunshine/blob/v2026.914.233613/src/nvhttp.cpp>
- Pinned Moonlight `NvHTTP.unpair()` implementation:
  <https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/nvstream/http/NvHTTP.java>
