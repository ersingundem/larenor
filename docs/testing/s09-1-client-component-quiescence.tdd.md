# S09.1 Client component-quiescence blocker contract

Date: 23 September 2026

This narrow Client slice starts from `origin/main` and does not change the
concurrent S09.1 export transport, bundle-size, recovery-preflight, or restore
passphrase files.

## Acceptance boundary

1. A Core plan blocked because the privileged component snapshot could not
   quiesce within its five-second deadline is a valid bounded plan, not a
   malformed Server response.
2. A Core plan blocked because component quiescence is unavailable is preserved
   for the existing blocked-plan UI.
3. Unknown blocker codes still fail closed as `invalid_response`; the Client
   does not accept arbitrary Server state.
4. Expanding the recognized-code allowlist does not relax the Server's maximum
   of eleven blocker entries.

This aligns the Client allowlist with the Server's versioned
`BackupPlanResponse` blocker contract. It does not add a privileged component
snapshot provider or run host/container effects.

## TDD evidence

After generated Dart sources were prepared, the RED test command was:

```sh
flutter test test/features/server/server_core_backup_quiescence_test.dart
```

Both supported component-quiescence cases failed with
`LarenorServerException(invalid_response)` while the unknown-code negative
control passed.

The GREEN focused command was:

```sh
flutter test \
  test/features/server/server_core_backup_quiescence_test.dart \
  test/features/server/server_core_backups_test.dart \
  test/features/server/server_core_backups_screen_test.dart
```

Result: 27 tests passed. The focused test covers both supported blocker codes,
the fail-closed unknown-code case, and the exact eleven-entry maximum.

## Remaining S09.1 gates

S09.1 remains pending. A production privileged component snapshot adapter,
component restore/rollback, large-volume native acceptance, full interruption
recovery, independent review, and exact-head CI remain separate gates. This
slice does not change `docs/execution-queue.json`, task status, or the counters
**26/125** and **0/63**.
