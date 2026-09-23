# F34 inventory authority and scanner lifetime

This slice closes three independent F34 client boundaries:

1. A throwing route-authority callback is converted to a bounded `cancelled` result before any Core request.
2. Every catalog, QR, history and grants response is followed by a fresh account generation, endpoint, Core/home and account identity check before the value can leave the gateway.
3. A QR scan is published only after the native camera close acknowledges within five seconds. A missing acknowledgement keeps reopen blocked until the original close really settles, and the old scan is never replayed.

## TDD evidence

- RED `b05f2dfd03db8c1865bfb04391ef026d5a0f4ca2`: throwing authority escaped as `StateError`, a page completed after authority drift, and scanner close had no total acknowledgement deadline or ownership fence.
- GREEN `d491d8f1c8700d7b36e907f91f374f85ea2ddb9c`: all 10 focused catalog/scanner tests pass.

F34 remains pending at **26/125 (20.8%)** and selected-feature progress remains **0/63 (0.0%)**. A real isolated Client-to-Core inventory E2E and exact-head full CI evidence are still required before the queue node can close; physical QR camera acceptance remains separate in the manual matrix.
