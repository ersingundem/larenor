# F43 presence-informed camera profile Core foundation

This slice treats presence as an untrusted policy input. It never grants account
or camera access. A live administrator authority and the exact live profile are
validated independently before evaluation and again before a provider command.
The contract controls only the advertised recording and detection modes; it does
not claim that a microphone, another recorder, or camera hardware is disabled.

## Acceptance criteria

1. **Explicit policy with safe transitions.** A versioned profile binds the
   exact Core, home, presence source, camera, area, service and binding revisions.
   Home and away transitions wait for their configured delay plus hysteresis.
   Unknown, stale or stabilizing presence selects a recording-enabled fail-safe
   mode. A manual override is administrator-bound, profile-revision-bound,
   limited to 24 hours and returns to fail-safe at expiry.
2. **One-shot worker effect with readback.** Core produces a closed command for
   the exact policy and last camera state revision. The provider/HA worker is a
   separate callable boundary. Success requires a newer, exact camera/binding
   readback matching both requested recording and detection state; partial,
   malformed and missing acknowledgements remain visible. A lost acknowledgement
   becomes `unknown`, and concurrent or repeated use of the same request ID
   returns its stored receipt without automatically dispatching again.
3. **Revision and audit integrity.** Evaluation and dispatch reject stale
   account, home, policy, source, camera, area, binding and service facts. A
   bounded HMAC-authenticated audit chain records command-batch and result
   payload hashes with immutable actor/request/profile attribution. Restore
   rejects modified payloads, links or head authentication before use.

## Evidence and remaining gates

The focused pytest suite covers permission separation, EN/TR-independent closed
contracts, transition timing, fail-safe and override expiry, stale revisions,
exact readback, partial/lost ACK behavior, concurrent idempotency, audit limits
and tamper detection. This foundation does not register HTTP routes, persist the
command receipt journal across restart, implement Home Assistant or camera-vendor
workers, prove physical camera behavior, or provide Android Client-to-Core E2E.
Those gates remain open, so queue progress stays **21/125 (16.8%)** and selected
feature progress stays **0/63 (0.0%)**.
