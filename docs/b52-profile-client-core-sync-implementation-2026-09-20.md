# B5.2 personal profile Client/Core sync acceptance

Status: implementation complete on the integration branch; program progress
stays **21/125** and feature progress stays **0/63** because this software
slice does not close the physical remote-session and release gates.

## Acceptance matrix

| Acceptance | Production result | Evidence |
| --- | --- | --- |
| Source and scope | Remote Access presents explicit **On this tablet** and **Larenor Core** sources. The Client uses the typed `/core-remote-profiles/{core}/{home}` contract and accepts its closed authority envelope only for the active Core, home, account ID, authenticated session-family ID, account revision and collection revision. Replacing or signing out the account retires the in-memory snapshot; route, idle and background loss retire the surrounding personal-session capability. | Exact path/envelope, foreign-family/account-revision, closed-model and personal-session boundary tests; EN/TR tablet tests at 600 and 1200 logical pixels with 2x text. |
| Conflict recovery | Every create/update/delete carries a fresh bounded request ID and the last verified account/collection revisions; update/delete also carry the record revision. A 409 keeps the old row as stale, disables mutation, and presents an explicit refresh-to-resolve action. The Client never overwrites automatically. Every accepted mutation validates the mutation authority then performs a full list readback at that exact authority before becoming verified again; rollback or changed data under an unchanged revision fails closed. | Request-shape, conflict, stale-readback and rollback controller tests plus the inherited Server idempotency and optimistic-revision integration tests. |
| Offline, restart and private state | Core rows are memory-only. A failed refresh may retain them solely as an offline/stale read-only cache; it cannot show them as current verified data. A lost write response stays uncertain and is reconciled by a fresh list after restart; the Client does not replay the mutation, and repeated readback remains idempotent. Client request/response models contain only label, protocol, host, port, username and revision. Password, token, secret, PIN and lease fields fail the closed parser and are never copied into Core metadata or diagnostics. | Lost-response/restart readback, closed-model, request-body, offline-cache and late session-family retirement tests; Server secret/log/database tests. |

The Core surface uses the same Cupertino `AppPageScaffold`, `SettingsSection`, action tiles and evidence component as the rest of Settings. All actions have at least a 48 logical-pixel target, support Tab/Enter through the shared action tile, expose live-region state where authority changes, and were exercised in English and Turkish at 600/1200 widths with 2x text scaling.

## Verification commands

```text
flutter test test/features/remote_access/core_personal_profiles_test.dart test/features/remote_access/core_personal_profiles_tablet_test.dart
flutter test test/features/remote_access/personal_session_boundary_test.dart test/features/remote_access/personal_session_boundary_tablet_test.dart test/features/remote_access/remote_profiles_screen_test.dart
flutter test test/features/remote_access/remote_profiles_tablet_test.dart
flutter analyze lib/features/remote_access lib/features/server/data/larenor_server_api.dart test/features/remote_access/core_personal_profiles_test.dart test/features/remote_access/core_personal_profiles_tablet_test.dart
python -m pytest -q server/tests/test_personal_profiles.py
```

After rebasing onto the merged notification runtime, direct-connect tablet and
family-board Core changes, the combined six-file Flutter gate passed **44/44**
tests and the scoped analyzer reported no issues. The narrow 320 logical-pixel
path now scrolls lazy profile actions into view before exercising them. EN/TR
ARB files were regenerated and validated as JSON; the queue, security and
commit-progress policies also pass.
