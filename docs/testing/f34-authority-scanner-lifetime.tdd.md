# F34 inventory authority and scanner lifetime

This slice closes three independent F34 client boundaries:

1. A throwing route-authority callback is converted to a bounded `cancelled` result before any Core request.
2. Every catalog, QR, history and grants response is followed by a fresh account generation, endpoint, Core/home and account identity check before the value can leave the gateway.
3. A QR scan is published only after the native camera close acknowledges within five seconds. A missing acknowledgement keeps reopen blocked until the original close really settles, and the old scan is never replayed.

## TDD evidence

- RED `7f3aa502`: throwing authority escaped as `StateError`, a page completed after authority drift, and scanner close had no total acknowledgement deadline or ownership fence.
- GREEN `52cc26ec`: all 10 focused catalog/scanner tests pass.

Independent review found that a native close which completed with an error
cleared the ownership fence and allowed a second camera flight. RED commit
`074b5c30` preserves that regression; GREEN commit `cbf3b2fc` keeps failed
close ownership permanently fenced while manual entry remains available. The
final focused catalog/scanner batch passes **11/11** tests and targeted analysis
remains clean.

F34 remains pending at **26/125 (20.8%)** and selected-feature progress remains **0/63 (0.0%)**. A real isolated Client-to-Core inventory E2E and exact-head full CI evidence are still required before the queue node can close; physical QR camera acceptance remains separate in the manual matrix.
