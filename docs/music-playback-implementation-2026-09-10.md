# Verified Music Assistant playback control

This slice adds encrypted player snapshots and explicit, revision-bound playback
commands after at least one Music Assistant provider has completed exact loaded
readback. Larenor Client can read available players, their advertised controls,
queue availability, AirPlay/HomePod classification, and exact group membership.

Every effect carries an authenticated user, idempotency key, expected managed
installation and Music Assistant Core revisions, expected player snapshot
revision, target ID, and exact expected group member list. Core journals the
intent before dispatch. A repeated request returns the saved receipt and never
runs the effect again. Worker failure leaves an `effect_unknown` record; Larenor
does not automatically retry or start playback.

The private Worker authenticates to the fixed loopback Music Assistant API. It
reads the exact target before dispatch, executes one requested command, and
reads the target again before returning success. Token, provider credentials,
media URIs, and private upstream responses stay in encrypted storage or private
IPC and never enter the public receipt. Product installation remains
`installAvailable=false`.

## Reviewed upstream commands

The contract was reviewed on 2026-09-10 against Music Assistant server commit
[`e1e0f59`](https://github.com/music-assistant/server/commit/e1e0f59b98726791eade15c0e26ed0c6da9a0b7c):

- [`players/all` and `players/get`](https://github.com/music-assistant/server/blob/e1e0f59b98726791eade15c0e26ed0c6da9a0b7c/music_assistant/controllers/players/controller.py#L416)
  provide authenticated player state and require player-read scope.
- [Player transport, volume, mute, and grouping commands](https://github.com/music-assistant/server/blob/e1e0f59b98726791eade15c0e26ed0c6da9a0b7c/music_assistant/controllers/players/controller.py#L637)
  are the `players/cmd/*` handlers and require player-control scope.
- [`player_queues/all`, `get`, and `items`](https://github.com/music-assistant/server/blob/e1e0f59b98726791eade15c0e26ed0c6da9a0b7c/music_assistant/controllers/player_queues/controller.py#L260)
  are the authenticated queue readback commands.
- [`player_queues/play_media`](https://github.com/music-assistant/server/blob/e1e0f59b98726791eade15c0e26ed0c6da9a0b7c/music_assistant/controllers/player_queues/controller.py#L489)
  accepts explicit `add` and `replace` queue options; queue clearing uses
  [`player_queues/clear`](https://github.com/music-assistant/server/blob/e1e0f59b98726791eade15c0e26ed0c6da9a0b7c/music_assistant/controllers/player_queues/controller.py#L630).
- [The AirPlay player implementation](https://github.com/music-assistant/server/blob/e1e0f59b98726791eade15c0e26ed0c6da9a0b7c/music_assistant/providers/airplay/player.py)
  confirms that grouped playback has provider-specific behavior. Larenor binds
  commands to the exact observed target and member IDs rather than inferring a
  group by display name.

## Acceptance boundary

The contracts and simulated private runtime are covered here. Real HomePod
discovery, AirPlay pairing/network behavior, synchronized group playback, and
real-account provider playback remain physical-system acceptance items. This
slice does not claim them complete.
