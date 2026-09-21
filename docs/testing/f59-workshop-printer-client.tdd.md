# F59 workshop printer tablet Client — TDD evidence

## Acceptance boundary

This slice consumes the F59 Core printer projection through a strict, account-
and-home-scoped Client API. It intentionally records bounded pause/cancel
intents only; it does not claim that OctoPrint received or executed a command.

The three software acceptance criteria are:

1. The read-only tablet surface shows printer, job, material and safety state.
   Offline, stale, thermal, filament, door and emergency hazards are written as
   text with an icon and remove every available action; unknown fields, foreign
   homes and secret-bearing projections fail closed.
2. Pause/cancel requires a current exact printer/service/job/material/safety
   revision, then a separate preview and explicit confirmation. Confirmation
   receipts remain `notDispatched`; lost acknowledgement or stale authority is
   never retried automatically.
3. The EN/TR surface adapts from one column at 600 logical pixels to two at
   1280, remains usable at 2x text scale, exposes 48dp actions, and supports
   keyboard activation and labelled TalkBack semantics.

## RED

- `8b07e915` introduced API, controller and widget contracts before the F59
  Client implementation existed. The focused test target failed to compile on
  the missing workshop modules.

## GREEN

Validation on 2026-09-21:

- Focused API/controller/tablet suite: 9 passed.
- EN/TR responsive matrix: 600 and 1280 logical pixels at 2x text scale passed.
- Explicit keyboard confirmation and TalkBack label test passed.
- Focused Flutter analyze, repository security policy, queue/progress policy,
  diff check and redacted secret scan are required before handoff.

## Remaining physical acceptance

The feature still needs route wiring through the authenticated app shell and a
physical 600/1280-class Android tablet acceptance run. A disposable OctoPrint
fixture must prove real readback and delivery before the Core worker may report
anything beyond `notDispatched`. No physical printer, Huawei tablet, Samsung
DeX or production OctoPrint acceptance is claimed by this slice.
