# F28 durable long-form sleep timer — 30 September 2026

The long-form screen now schedules a real pause against the selected Music
Assistant receiver. The timer is a sealed server-side journal rather than a
Client delay. Its authority binds the current account, actor, session family,
user revision, long-form session revision, installation and Core revisions,
Music Assistant snapshot revision, provider, player, group members, queue and
media URI. No provider token or other credential is written to the timer
journal.

At the deadline Core claims one pending timer and never sends it a second time.
A restart before the deadline retains the pending timer. A restart after an
unresolved dispatch changes it to `needs_attention/effect_unknown`; it does not
guess success or retry. Clearing the timer, losing the session family, changing
the user revision, changing the selected queue/player or changing the media
cancels or fails closed before device mutation.

The provider worker performs the decisive check. Immediately before pause it
reads the actual player and all Music Assistant queues, requires the exact
current media URI, then reads the player and queue again after pause. A changed
provider queue therefore produces no pause request even when Core's encrypted
snapshot still names the old item. A successful receipt requires both paused
state and the same queue media identity. This follows the pinned Music
Assistant 2.10.4 command surface for
[`players/*`](https://github.com/music-assistant/server/blob/2.10.4/music_assistant/controllers/players/controller.py)
and
[`player_queues/*`](https://github.com/music-assistant/server/blob/2.10.4/music_assistant/controllers/player_queues/controller.py).

The existing route paths remain unchanged. The long-form body/response contract
is schema version 2 because it carries the selected receiver and explicit timer
state. The v1 database migration preserves existing session rows and their
bookmarks/progress, but deliberately creates no executable timer from a legacy
`sleep_ends_at` value: that value did not contain enough receiver or authority
information for a safe write.

A different authenticated session family may take over only after it proves the
current installation, Core, Music Assistant revision and exact provider/catalog
item. While the pause is dispatching, that otherwise valid public request gets
`longform_sleep_timer_dispatch_in_progress` and cannot replace the session or
cancel the journal. Once dispatch reaches a durable terminal outcome, the
successor may retry with a fresh provider snapshot. The takeover preserves
`authenticated_readback` after success or `effect_unknown` after a lost
acknowledgement, and neither path sends the old pause again.

The IPC boundary cannot prove that an effect did not cross after the worker
accepted a command and the reply was lost. Core therefore leaves the underlying
command pending and the sleep timer at `needs_attention/effect_unknown` across
restart or session handoff. That state is deliberately not converted to success
and is never an automatic retry; only a later authenticated provider observation
or explicit new user action can establish a new effect.

## Executed evidence

- `cd server && uv run --frozen pytest -q tests/test_f28_longform_catalog.py tests/test_f28_longform_sleep_timer.py tests/test_music_playback.py tests/test_music_playback_runtime.py tests/test_music_manager_api.py`: 57 passed. This includes real runtime pre/post queue checks, provider-only media drift with a stale Core snapshot, cancellation and authority retirement with zero pause I/O, controlled public takeover during an in-flight provider effect, success and lost-ack terminal preservation without replay, last-minute progress without deadline replacement, strict v2 mutations, and v1 migration.
- `flutter test --no-pub test/features/server/server_music_longform_api_lifecycle_test.dart test/features/server/server_music_longform_card_test.dart test/features/server/server_music_longform_models_test.dart test/features/server/server_longform_sleep_timer_test.dart`: 21 passed, including the visible sleep control, exact receiver body and strict contradictory/legacy readback rejection.
- Focused `flutter analyze` over the three production long-form files and two new tests: no issues.
- `cd server && uv run --frozen python tests/support/f28_flutter_acceptance.py`: two independent Flutter processes passed. The first real Client uses normal Core TCP to schedule the timer; normal Core sends one private action over the production Unix IPC client/server. The second normal Core and Client lifetime reads the authenticated terminal receipt and proves no second effect.

On Linux the acceptance uses the kernel `SO_PEERCRED` check. macOS does not
offer Linux `SO_PEERCRED`, so the disposable runner supplies the installation
IPC client's existing deterministic peer-UID seam while still using the real
Unix socket protocol and strict message models. A Linux host run remains the
evidence for the kernel peer-credential boundary.

Physical HomePod/Cast behavior, provider-account availability and host power
suspension remain manual/device checks. They are not substituted by this
software gate. The shipped background dispatcher, durable claim and worker
readback path now provide the missing software enforcement.

Root repeated the final real Client→normal Core→production Unix IPC→owned Music Assistant acceptance after the takeover/public-error repair: both lifetimes passed, with exactly one pause and no restart replay. The combined F22/F28 server gate passed 46 tests, the F47/F28 Flutter gate passed 37 tests, and scoped analysis found no issues. F28 is software-complete and awaits broad exact-HEAD CI; physical receiver acceptance remains separately manual.
