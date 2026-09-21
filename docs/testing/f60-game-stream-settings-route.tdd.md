# F60 tablet game-stream settings route — TDD acceptance

This stacked slice makes the fail-closed Android game-stream boundary visible
from the shared tablet Settings navigation. It does not add a streaming engine
or claim physical Moonlight/Sunshine, video, audio, codec, keyboard, controller,
network wake, or external-display acceptance.

## Acceptance matrix

| Criterion | Production evidence | Automated evidence |
| --- | --- | --- |
| Discoverable shared tablet route | `Game streaming` / `Oyun yayını` is a first-class split-view category using the same page scaffold, grouped sections, icon treatment, focus behavior, and nested navigation as the other settings panes. The screen distinguishes checking, unverified, unavailable, available, and read-error states. | Settings route tests cover keyboard activation, TalkBack semantics, live status, 48dp actions, EN/TR, 600px and 1280px widths at 2x text. Existing split/settings journeys remain green. |
| Exact personal-session to native-port authority | `GameStreamPersonalSessionBinder` requires identical personal account and route owners, exact session/source revisions, current PIN/foreground/route/interaction/idle authority, and current gate/route callbacks. It maps those revisions to one native epoch and retires exact bindings before replacement or after a stale callback. | Binder tests cover exact mapping, wrong owner/route/foreground rejection, route revision change during native bind, and idempotent exact retirement. Existing native-port and coordinator tests remain green. |
| Lifecycle and accessibility fail closed | Missing Settings gate authority disables native inspection. App pause, view focus loss, interaction epoch change, route replacement, hidden ticker, or late callback clears the verified result; returning to the screen never revives old evidence. All copy is localized and scroll-safe. | A deterministic delayed-capability test proves an expired interaction cannot publish a late success; the tablet matrix verifies keyboard/TalkBack behavior without overflow. |

## Focused verification

- `flutter test` across the settings route, personal binder, Android port, F60 coordinator, split-view, and shared settings accessibility suites: 39 tests.
- Targeted `flutter analyze` for production and test files.
- Repository queue, progress, security policy, secret scan, diff, open-PR overlap, and merge-tree checks are recorded with the final wrapper commit.
