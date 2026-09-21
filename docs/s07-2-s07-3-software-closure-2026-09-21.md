# S07.2 and S07.3 software closure

The unified package dependency is now on `main`, together with the automatic
media flow, continuity journal, Music Assistant manager API, tablet client, and
private key rotation. This review closes the software scope of S07.2 and S07.3
on `beb7e6098f668a41a45dfaefa6ac7661de0e0976`. Real provider accounts,
receivers, and home-server installation remain in the explicit manual gates.

## Three acceptance criteria

| Criterion | Accepted behavior | Evidence |
| --- | --- | --- |
| Request to playable continuity | Seerr, qBittorrent, Sonarr/Radarr, and Jellyfin share one revision-bound flow. Missing seasons, partial imports, hardlink identity, canonical path mapping, interruption, retry, and uncertain effects are explicit and fail closed. | `test_media_flow.py`; S07.2 implementation and continuity reviews; PR #230 Server and native stack checks |
| One managed music authority | Larenor Core owns provider setup, catalog, queue, receiver, and playback commands without a second Music Assistant address or token. Public contracts are secret-free; exact provider and receiver revisions plus post-effect readback are mandatory. Private key rotation is encrypted, restart-safe, idempotent, and rejects authority drift. | Music manager/playback/runtime/setup/rotation suites; S07.3 Core and tablet reviews; PR #231 Server and Music Assistant native checks |
| Integrated dependency and boundary | S07.1 supplies the six-component package and private worker path used by both flows. The integrated main tree passed 87 focused media/music/API tests locally. Physical Spotify, Apple Music, YouTube Music, HomePod, Cast, CasaOS, Proxmox, Huawei, DeX, keyboard, and TalkBack acceptance is not inferred from software fixtures. | S07.1 acceptance on PR #182; queue dependency validation; exact local `beb7e609` review |

## Verification

The following command passed **87/87** tests on the integrated main tree:

```text
python -m pytest -q tests/test_media_flow.py tests/test_music_manager_api.py
tests/test_music_playback.py tests/test_music_playback_runtime.py
tests/test_music_provider_setups.py tests/test_music_assistant_key_rotation.py
tests/test_api_boundary.py
```

PR #230 completed 29 required checks with no failure or pending job, including
Server, qBittorrent, Arr, Jellyfin, Music Assistant, unified amd64/arm64 stack,
security, and Android gates. PR #231 completed 31 required checks with the same
zero-failure result for the key-rotation addition. The S07.1 package dependency
was then accepted on exact CI and merged before this closure review.

This closes only the declared software acceptance. A successful fake transport
does not claim a real subscription login, LAN discovery, receiver pairing,
audio output, synchronized group, or live filesystem import.
