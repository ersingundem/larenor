# Music provider normal-Core acceptance — 2026-09-30

This gate covers the production onboarding boundary that the existing focused
tests previously exercised only as separate layers. It runs the real Flutter
provider setup controller against a normal restartable Core, the
production Unix installation IPC client/server, `MusicProviderSetupRuntime`,
and an owned TCP Music Assistant fixture. A widget regression also verifies
that a verified administrator reaches the setup screen from the music center.

The first Client lifetime reads the reviewed Spotify, Apple Music, and YouTube
Music support matrix, starts YouTube Music setup, loses the committed create
acknowledgement, and reconciles only the exact request ID. The Core then
restarts. A fresh Client lifetime restores the active setup, submits the exact
dynamic form with an obscured cookie field, and accepts completion only after
the authenticated provider instance readback reports `loaded`. It then starts
a new Spotify flow, accepts only the reviewed HTTPS accounts origin, and
explicitly cancels through the private worker. The fixture asserts one exact
upstream command sequence and verifies the submitted secret is absent from the
Core SQLite dump.

Run:

```sh
PYTHONPATH=server server/.venv/bin/python server/tests/support/product_music_provider_flutter_acceptance.py
```

The fixture uses synthetic credentials and an owned loopback provider. It does
not prove a Spotify, Apple Music, or YouTube Music subscription, playback
rights, provider approval, or a household Music Assistant deployment. Those
remain provider/account manual gates described in the implementation notes.

Named 30 September local results, repeated independently by root:

```text
actual Client/Core/private IPC/owned MA TCP: 2 phases, 2 tests each, no skips
provider Server/runtime focused suites: 26 passed
admin music-center navigation without the TCP fixture: 1 passed
standard no-fixture actual TCP test: explicitly skipped, not counted as acceptance
scoped Dart analyze: no issues
```

The local macOS IPC fixture substitutes Linux-only kernel peer UID discovery;
framing, configured UID comparisons and the production client/server/runtime
remain in use. Actual cross-UID Linux installation and peer credentials are a
separate hosted host-worker gate. Local success does not replace that evidence.
