# F60 uncertain session local close evidence — 2026-10-01

## Scope

An uncertain stream outcome blocks every effect command so Larenor never
replays a provider action. The settings route now offers a separate **Close
local session** action only when that uncertain state still owns an exact Core
session. This action uses the existing durable native-binding and Core-session
retirement path. It does not authorize or resend `stop`, and it does not claim
that Sunshine stopped or removed the pairing.

If native retirement, Core retirement, or recovery-store cleanup remains
uncertain, the encrypted cleanup record stays available and the controller
remains `outcomeUnknown`. The user can explicitly retry the same exact cleanup;
the controller does not redispatch the stream or stop command. A successful
cleanup refreshes the current host list and removes the local session.

Unknown pairing, catalog, and revocation outcomes without an active session do
not display the local-session action.

Cold recovery does not depend on the application picker state. When an exact
session is restored as unknown, the production settings route exposes the
session-owned local-close action even though no application is selected. A
refresh cannot replace that route controller while its exact retirement is in
flight; refresh stays disabled until cleanup finishes, then creates the
successor controller. The retirement response must echo the exact session ID
and `retired` state. A same-host/application response for another session keeps
the durable recovery record and remains unknown.

The close operation is generation-bound. Account, route, or successor work
that advances the controller generation makes a late cleanup completion inert,
so it cannot restore the old unknown snapshot or clear successor state.

## TDD evidence

The initial focused run failed at compile time because
`GameStreamClientController.closeLocalSession` and the production lifecycle
action did not exist. This was the expected RED state for the missing path.

The focused GREEN command was:

```text
flutter test --no-pub \
  test/features/game_streaming/game_stream_client_controller_test.dart \
  test/features/game_streaming/game_stream_settings_screen_test.dart
```

Result: 28 tests passed, 0 failed, 0 skipped. Scoped analysis of the two
production and two test files reported no issues.

The controller regression proves failed Core cleanup stays durable and unknown,
rejects a forged wrong-session retirement response, then succeeds on an
explicit retry without another native stop dispatch or native retirement. The
production-route regressions prove a cold recovered session shows the action
without a selected application and a same-owner refresh waits for exact prior
controller cleanup. The EN/TR widget regressions prove the uncertain active
session shows the local-close action instead of Stop, while a non-session
unknown outcome shows neither action.

## Limits

These tests prove local ownership cleanup and no replay in the Client contract.
They do not prove that a remote Sunshine stream stopped, that a remote
application exited, or that the Sunshine pairing was removed. Those outcomes
require their separate causal provider evidence.

Root final composed source gate passed **49 tests, 0 failures, 0 skips** across
the two game-stream controller/screen modules and the three offline Core/vault/
download-screen modules. This includes the final retry, route-disposal,
reentrant cleanup and cold-recovered session fixes; earlier named counts remain
source-specific evidence. Required broad branch-source CI remains separate.
