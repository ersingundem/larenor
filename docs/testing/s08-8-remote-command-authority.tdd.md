# S08.8 remote playback command authority boundary

This slice closes three lifecycle gaps in the existing one-use remote playback
controller. It does not close `S08.8`: queue progress remains **26/125** and
selected-feature progress remains **0/63**.

## Accepted behavior

- A throwing current-authority callback fails closed before a refresh or
  command preflight. It emits no raw callback error, performs no network read
  or command, and retires the previously visible receiver evidence.
- A silent authority loss while the controller awaits the playback command
  result cannot publish the old success, error, receiver list or busy state.
  The already-sent command remains single-shot and gains no receipt under the
  replacement authority.
- An intent consumed by a failed authority check cannot become replayable when
  authority later recovers. Recovery requires fresh discovery and a newly
  prepared intent; the original operation identity never sends a command.

## TDD evidence

RED commit `e66a607fcc7b7422f210f4eaf72541304c98047b` added the three regressions.
The old controller leaked the callback `StateError`, retained stale target and
busy state after the awaited command, and allowed the rejected intent to be
retried. GREEN commit `d1cc280170a9cff8653b71c25d4d563c2bef8fb7`
contains authority callback failures, retires stale operations after each
await, and consumes the one-use intent before the authority check.

The focused remote playback controller package passes **33/33** tests,
including the existing target identity, item preflight, timeout/uncertain
outcome, lifecycle, observation and duplicate-tap matrix. Targeted Flutter
analysis covers the changed controller and focused test.

Independent review found that a listener added after silent authority loss
received the retained old-authority snapshot before the controller evaluated
the authority callback. RED commit `74b30262` fixes the regression boundary;
GREEN commit `30559738` now retires authority before subscribing or emitting
the retained snapshot. The final focused controller batch passes **34/34**
tests, and targeted analysis remains clean.

## Remaining S08.8 acceptance

Other direct media service paths still need central Core replacements. The
wider same-URL Core replacement/logout journey still needs Android E2E,
independent review and exact-head CI, so neither progress counter changes.
