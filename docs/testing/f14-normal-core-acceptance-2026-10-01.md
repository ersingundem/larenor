# F14 normal Core support-session acceptance — 2026-10-01

This gate runs the production Flutter account, support-session API and
controller against a normal `create_app` Core through a real loopback Uvicorn
TCP listener. It uses two independent Flutter processes and restarts Core on
the same encrypted database between them.

The first lifetime proves:

- list and create use the current administrator, Core and home authority;
- the 43-character support bearer is exposed by the controller once, remains
  process-private, performs one real bounded `core:health.read`, and is never
  written to the checkpoint;
- the resulting allowed activity is read through the production detail route;
- a deliberately discarded create response becomes `connection_failed`, and
  explicit GET-only refresh reconciles the created record without a second
  POST or attempted bearer recovery;
- a hidden route, a remotely demoted administrator, a replaced login family,
  and a different normal Core/home cannot publish a token or retain stale
  controller state.

The second lifetime restores the Client account from a private mode-0600 test
store, starts normal Core from the same database, lists both records, reads the
persisted activity, and revokes both records by their current revisions. The
support bearer itself is never persisted, so restart can manage or revoke the
record but cannot redisplay the issued credential.

Run the focused evidence with:

```sh
cd server
uv run --frozen python -m pytest -q tests/test_f14_support_sessions_normal_core.py
uv run --frozen python tests/support/f14_flutter_acceptance.py
```

Executed results on 2026-10-01: the existing normal-Core Server gate passed
3/3 tests. The combined acceptance runner then passed its single named Flutter
test in both fresh processes: one prepare lifetime and one restarted lifetime.
The production Client/controller companion gate passed 11/11 focused tests and
its scoped analysis was clean. Root independently repeated the two-process normal
Core acceptance, the 11-test Client suite and scoped analysis. A platform
clipboard-write exception first reproduced as a failed widget regression; the
corrected dialog now shows a localized error, keeps explicit retry/close usable
and never claims copy success or changes retired authority.

This is software evidence for the Core and Client lifecycle. It does not prove
an external support organization, remote screen control, a shell, free-form
log collection, or any household-device access; those capabilities are not
provided by F14.
