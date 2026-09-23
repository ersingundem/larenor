# K03 live Web Panel data-clear barrier

This slice closes three independent races in the destructive Web Panel data-clear path:

1. A throwing current-authority callback fails closed before any renderer retirement or native data mutation.
2. A renderer retirement registered while a native clear call is pending joins the same barrier and must settle before the next mutation or success.
3. A panel registered while clear is running is retired into that active barrier, so it cannot escape the initial panel snapshot.

## TDD evidence

- RED `662640c8aee1d04f843d18b3c90e8d51a0feb117`: 3 new contract tests failed; the authority exception escaped and both late registration cases allowed storage/cache clearing before retirement.
- GREEN `48e198831f14ccc6fa4e05990710d5e1490182e5`: all 9 focused coordinator tests pass. The barrier drains after every asynchronous native mutation and still remains bounded by the existing 20-second total deadline.

Queue progress remains **26/125 (20.8%)** and selected-feature progress remains **0/63 (0.0%)**. K03 remains open for the remaining exact-head CI, device and release evidence.
