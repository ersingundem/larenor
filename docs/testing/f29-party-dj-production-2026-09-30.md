# F29 Party DJ production acceptance

The named F29 gate uses a loopback TCP Music Assistant fixture with the normal
Core composition and the production `MusicPlaybackRuntime`. It creates and
joins a room through the public Party DJ routes, verifies an exact catalog
track, records two participants' votes, and approves the proposal through
`player_queues/play_media` with `option: add`. The fixture applies that effect
once and the runtime requires a larger authenticated queue readback before Core
marks it complete.
The same path records the two-person skip quorum and issues one
`players/cmd/next`, whose pinned Music Assistant implementation redirects the
active player to its queue controller.

The restart case opens a new normal Core against the same SQLite database. The
proposal, votes, actor/session ownership, Music Assistant authority, and queue
effect journal survive. Replaying the same vote request returns its saved
result without adding a vote. A second distinct up-vote from the same actor is
also constrained by the proposal/account primary key in the durable schema.

The lost-ack case applies the queue add and closes the TCP connection before
the response. Core retains the pre-I/O playback command and Party DJ claim.
Retries before and after restart read that journal and never call
`player_queues/play_media` again. After the bounded reconciliation interval,
the proposal becomes `needs_attention`; Core does not infer causality from the
current queue or fabricate success.

Music Assistant 2.10.4 is the exact pinned production image. Its primary source
registers `player_queues/play_media`, accepts `QueueOption.ADD`, and registers
`players/cmd/next`, which redirects an active player to its queue controller:

- <https://github.com/music-assistant/server/blob/2.10.4/music_assistant/controllers/player_queues/controller.py>
- <https://github.com/music-assistant/server/blob/2.10.4/music_assistant/controllers/players/controller.py>
- <https://www.music-assistant.io/api/>

Focused command:

```text
server/.venv/bin/python -m pytest -q \
  server/tests/test_f29_party_dj_normal_core.py \
  server/tests/test_music_playback_runtime.py \
  server/tests/test_music_playback.py \
  server/tests/test_music_manager_api.py
```

The focused gate passed 35 tests. Exact-HEAD broad CI remains open.

The fixture owns all requests and credentials. It sends no household command.
Physical receiver behavior and concurrent real Music Assistant clients remain
manual provider evidence.
