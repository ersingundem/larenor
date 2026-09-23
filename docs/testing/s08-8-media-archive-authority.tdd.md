# S08.8 media archive authority boundary

This slice closes a lifecycle gap in the central, read-only media archive
health controller. It does not close `S08.8`: queue progress remains
**26/125** and selected-feature progress remains **0/63**.

## Accepted behavior

- A successful archive read may publish only while the exact authority
  revision captured before the read is still current. A silent home/account
  generation change retires the result even when no notifier fires.
- A failed archive read follows the same exact-revision rule. Offline, stale,
  denied and unsupported states from an old authority cannot appear in a new
  lifecycle.
- Authority and revision callbacks are fail-closed before and after the await.
  A callback failure before the read performs no Core request and publishes a
  denied state; a failure after the read retires the operation without
  publishing its snapshot or error.

## TDD evidence

RED commit `c21061270497914bd95f5a5564b2b6f601f1af68` added delayed success,
delayed failure and throwing-callback regressions. The old controller published
both delayed outcomes after a silent revision change and allowed a revision
callback exception to escape its constructor. GREEN commit
`39cc624858c20a2de4ea26376eba4d9b34fbadd0` captures the revision before each
read, rechecks exact authority after every await, and keeps callback failures
inside a closed boundary.

The focused archive controller/model/card/detail package passed **26/26**
tests. It includes the new authority matrix plus the existing English/Turkish
TalkBack, keyboard, 2x text and 600/1280 logical-pixel evidence. Targeted
Flutter analysis covers the changed controller and regression test.

## Remaining S08.8 acceptance

Direct media service clients still need central API replacement, and the wider
same-URL Core replacement/logout journey still needs Android E2E, independent
review and exact-head CI. Those gates keep both progress counters unchanged.
