# Core people return transition — 2026-09-06

This test-only repair starts from `e7c15ad6f62352f77379e369f3e8524028c42aab`.
The member people journey could observe the underlying Core route as current,
with tickers enabled, while the outgoing People route remained mounted during
its reverse transition. Its immediate `findsNothing` assertion could therefore
run before route disposal.

`corePeopleJourneyWaitForReturn` now requires the outgoing `home-people-list`
to be absent, including offstage elements, and retains the original Core
route-current/TickerMode predicate. It uses the existing bounded `waitUntil`;
the back action remains one tap. The following absence assertion, 500 ms
no-repeat-read check, fresh explicit read, and all home-effect checks remain.
Application code, shared tap helpers, and timeouts are unchanged.

## Runtime evidence

- RED `911c769`: two actual `PeopleUiHarness`/Navigator/HomePeopleScreen tests
  fail at outgoing-list absence, with normal and 4× slowed animation. Both
  already observe Core route-current and enabled tickers. The initial helper
  extraction preserves the old predicate exactly.
- GREEN `9342c56`: the same two cases pass after the added absence predicate.
  `timeDilation` is always restored in `finally`. A fresh explicit opening is
  the only next people-list request; HA factories, mutations, user-list and
  grant requests remain unused.
- An intermediate GREEN attempt reached and passed the repaired route check,
  then failed an invalid additional fixture assumption that *all Core resource*
  reads were zero. The existing Core home resource reader is outside that
  oracle. Removing that new assumption preserves the native journey's actual
  people-read and zero-HA/mutation boundaries; its failure log is retained.
- Final related run: **42 passed**, including the two new tests and existing
  People UI, authorization/retirement, PIN, recovery and stale-callback tests
  (16 seconds). The two-file analyzer reports zero issues; formatter reports
  two files, zero changes. Flutter's LCOV output covers application files but
  excludes this `integration_test` helper, so no helper coverage percentage is
  claimed.

Logs are `/private/tmp/larenor-people-back-red.log`,
`/private/tmp/larenor-people-back-green.log` (intermediate fixture failure),
`/private/tmp/larenor-people-back-green-final.log`,
`/private/tmp/larenor-people-back-related.log`,
`/private/tmp/larenor-people-back-analyze.log` and
`/private/tmp/larenor-people-back-format-final.log`.

## Preservation and limits

The offline exact-source manifest comparison preserves all **13 app scenarios,
4 platform scenarios and 133 ordered markers**, including every title.
`app_journeys_test.dart`, AppHarness, archive and people-admin journeys are
byte-identical to the base. The People journey body differs only in extracting
its original wait into the helper; the helper adds the outgoing-route check.
The receipt is `/private/tmp/larenor-people-back-preservation.json`.

Root independently reviewed the behavioral source and tests at `9342c56`
with no open P1/P2 finding. The later source delta is formatting only.

This is a local reproduction of a readiness gap, not a claim that the People
journey caused CI106's failure: that run failed in archive confirmation
cancellation. No Android emulator run, CI query/rerun, APK transfer, live Core,
HA or home-device operation was performed for this repair. Native acceptance
belongs to the next exact-source CI run.
