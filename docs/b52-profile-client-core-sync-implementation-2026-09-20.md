# B5.2 personal profile Client/Core sync acceptance

Status: implementation complete on the integration branch; program progress stays **17/125** and feature progress stays **0/63** until the physical remote-session and release gates close.

## Acceptance matrix

| Acceptance | Production result | Evidence |
| --- | --- | --- |
| Source and scope | Remote Access presents explicit **On this tablet** and **Larenor Core** sources. Core metadata is parsed through a closed schema and accepted only for the active account's exact Core/home context, account generation (the Client's session-family epoch), and record/collection revision. Replacing or signing out the account retires the in-memory snapshot; route, idle and background loss retire the surrounding personal-session capability. | `core_personal_profiles_test.dart`; personal-session boundary tests; EN/TR tablet tests at 600 and 1200 logical pixels with 2x text. |
| Conflict recovery | Every update/delete carries the last verified record revision. A 409 keeps the old row as stale, disables mutation, and presents an explicit refresh-to-resolve action. The Client never retries or overwrites automatically. Every accepted mutation performs a full list readback and requires the exact collection revision delta before becoming verified authority again; rollback or changed data under an unchanged revision fails closed. | Conflict, stale-readback and rollback controller tests plus the inherited Server optimistic-revision integration tests. |
| Offline, restart and private state | Core rows are memory-only. A failed refresh may retain them solely as an offline/stale read-only cache; it cannot show them as current verified data. A lost write response stays uncertain and is reconciled by a fresh list after restart; the Client does not replay the mutation, and repeated readback remains idempotent. Client request/response models contain only label, protocol, host, port, username and revision. Password, token, secret, PIN and lease fields fail the closed parser and are never copied into Core metadata or diagnostics. | Lost-response/restart readback, closed-model, request-body, offline-cache and late session-family retirement tests; Server secret/log/database tests. |

The Core surface uses the same Cupertino `AppPageScaffold`, `SettingsSection`, action tiles and evidence component as the rest of Settings. All actions have at least a 48 logical-pixel target, support Tab/Enter through the shared action tile, expose live-region state where authority changes, and were exercised in English and Turkish at 600/1200 widths with 2x text scaling.

## Verification commands

```text
flutter test test/features/remote_access/core_personal_profiles_test.dart test/features/remote_access/core_personal_profiles_tablet_test.dart
flutter test test/features/remote_access/personal_session_boundary_test.dart test/features/remote_access/personal_session_boundary_tablet_test.dart test/features/remote_access/remote_profiles_screen_test.dart
flutter analyze lib/features/remote_access lib/features/server/data/larenor_server_api.dart test/features/remote_access/core_personal_profiles_test.dart test/features/remote_access/core_personal_profiles_tablet_test.dart
python -m pytest -q server/tests/test_personal_profiles.py
```
