# S08.8 music cache authorization-loss boundary

This slice closes one lifecycle gap in the central Core music snapshot cache.
It does not close `S08.8`: queue progress remains **25/125** and selected-feature
progress remains **0/63**.

## Accepted behavior

- A retained Core installation may use its exact tuple/revision-bound cached
  manager only after the live manager request ends with a non-authority failure.
  The fallback remains unverified and unreachable, so it grants no command.
- `forbidden`, `invalid_session`, and `password_change_required` responses never
  publish the cached manager. Provider, receiver, queue and catalog selections
  therefore cannot survive a known authorization loss.
- The retained installation read must still succeed first. A cache record alone
  cannot establish current Core/home/account or installation authority.

## TDD evidence

RED commit `5f58f566b29467677308f33d97e1e516831932b1` restored a valid cached manager,
then returned HTTP 403 from the live manager endpoint. The controller incorrectly
left the cached manager published. GREEN commit
`62b523a50bdfdb773354159420894a39e48338c1` delays cache publication until the
live read fails and denies fallback for authority failures.

The focused cache, controller, model, retained-state and EN/TR tablet UI package
passed **39/39** tests, including 600/1200 px layouts at 2x text scale. Targeted
Flutter analysis passed for the changed controller and regression test.

## Remaining S08.8 acceptance

Direct Jellyfin catalog/search/playback and direct Music Assistant onboarding
still require central API replacement. Legacy provider/player mapping still
needs explicit preview and confirmation. The wider media records and integrated
same-URL Core replacement/logout journey still need independent review, Android
E2E and exact-head CI before `S08.8` can close.
