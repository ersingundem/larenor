# S08.8 music cache authorization-loss boundary

This slice closes one lifecycle gap in the central Core music snapshot cache.
It does not close `S08.8`: queue progress remains **25/125** and selected-feature
progress remains **0/63**.

## Accepted behavior

- A retained Core installation may use its exact tuple/revision-bound cached
  manager only after the live manager request ends with an explicitly retryable
  `connection_failed`, `timeout`, `server_error`, or `rate_limited` failure. The
  fallback remains unverified and unreachable, so it grants no command.
- `forbidden`, `invalid_session`, and `password_change_required` responses never
  publish the cached manager. Provider, receiver, queue and catalog selections
  therefore cannot survive a known authorization loss.
- An active manager HTTP 401 (`unauthorized`) escapes the manager callback so
  `ServerAccountController.withSession` retires the exact account session. The
  controller consequently publishes neither a cached manager nor a live one.
- The retained installation read must still succeed first. A cache record alone
  cannot establish current Core/home/account or installation authority.

## TDD evidence

RED commit `5f58f566b29467677308f33d97e1e516831932b1` restored a valid cached manager,
then returned HTTP 403 from the live manager endpoint. The controller incorrectly
left the cached manager published. GREEN commit
`62b523a50bdfdb773354159420894a39e48338c1` delays cache publication until the
live read fails and denies fallback for authority failures.

Follow-up RED commit `7c47be5715a30f763686f2c6193d12fc5ff1812b`
proved that an HTTP 401 was swallowed inside the manager callback, leaving both
the cached manager and account session alive. GREEN commit
`b45c02503e061463b1324694c970251964af1936` rethrows `unauthorized` to the normal
account revocation boundary and replaces the broad negative check with the
bounded retryable-failure allowlist above.

The focused cache, controller, model, retained-state and EN/TR tablet UI package
passed **40/40** tests, including 600/1200 px layouts at 2x text scale. Targeted
Flutter analysis passed for the changed controller and regression test.

## Remaining S08.8 acceptance

Direct Jellyfin catalog/search/playback and direct Music Assistant onboarding
still require central API replacement. Legacy provider/player mapping still
needs explicit preview and confirmation. The wider media records and integrated
same-URL Core replacement/logout journey still need independent review, Android
E2E and exact-head CI before `S08.8` can close.
