# K14 capability evidence registry TDD evidence

Date: 23 September 2026

Larenor previously had no durable boundary between a configured kiosk feature,
an automated test result, and a physical-device result. That made unsupported
Huawei, Android desktop-window and DeX claims indistinguishable from verified
behavior.

## Acceptance boundary

This slice completes three related jobs:

1. Larenor Core stores at most 256 evidence records with one of four exact
   outcomes: `tested`, `failed`, `untested`, or `manual_required`. Each record
   binds the capability and device environment to a safe artifact name,
   SHA-256 digest, source commit, and test-case identifier. Records and replay
   receipts are authenticated at rest; schema, attached-index/trigger, record,
   family, and integrity drift fail closed on startup and read.
2. Larenor Client reads only the authenticated Core/home scope through a
   bounded, strictly ordered cursor contract. Unknown public fields, malformed
   targets, unsafe evidence links, duplicate permissions, cursor drift, and
   responses above the 256-record ceiling are rejected as `invalid_response`.
3. Settings exposes an EN/TR tablet surface with all four outcomes, a 48 dp
   keyboard-operable refresh target, 600/1280 layouts at 2x text, and lifecycle,
   route, account, Core, home, administrator, and Settings-gate retirement.
   Late authority responses are discarded and old evidence is hidden.

No token, request key, payload hash, local path, remote URL, or unrestricted
artifact content enters the public record.

## RED

Commit `686393a0051c782ac48404327b19dafd90877c2e` records the rebased acceptance
tests. All three Server cases failed with a missing endpoint, while the Flutter
suite failed to compile because the strict model and evidence surface did not
exist.

## GREEN verification

The implementation adds the authenticated Core registry, strict Client parser,
and tablet Settings route. Focused verification on the final worktree passed:

```text
server: 6 tests passed
client: 8 tests passed
targeted flutter analyze: no issues
ruff format/check: passed
```

Repository security, execution-queue, progress-trailer, generated-localization,
and diff checks run once on the final commit. This supporting K14 slice does not
change `docs/PROGRESS.md`, `docs/execution-queue.json`, or the counters
**26/125** and **0/63**.

## Physical acceptance still required

Automated widget evidence cannot promote Huawei MatePad 11.5 S 2026,
Samsung DeX external-display behavior, OS permission dialogs, background power
policy, WebView lifecycle, camera, microphone, wake, or lock-task behavior to
`tested`. Those results remain `manual_required` until a matching artifact is
captured on the physical target and published through the administrator-scoped
Core API.
