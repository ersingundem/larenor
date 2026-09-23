# K03 explicit external app actions

Status: **software slice ready; K03.remaining stays open**

## Three acceptance tasks

1. **Strict target contract.** WebPanel accepts only bounded, query-free
   `mailto:`, `tel:` and numeric `geo:` main-frame targets. `intent:`, SMS,
   JavaScript, encoded/control characters, credentials, fragments, queries,
   invalid coordinates and unknown schemes remain blocked.
2. **Fresh, one-shot consent.** External actions are disabled per panel by
   default. The user must arm a 30-second foreground grant, review the exact
   safe display target and confirm it. Account, route, lifecycle or controller
   retirement invalidates the grant and late results cannot replay it.
3. **Tablet-ready handoff.** EN/TR controls expose at least 48dp targets,
   keyboard and accessibility semantics, and fit 600/1200 tablet widths with
   2x text. Android receives one external-application request. A successful
   handoff is shown as unconfirmed because Larenor cannot observe the other
   application's result; it is never retried automatically.

## Automated evidence

- The parser/controller suite covers accepted targets, rejection boundaries,
  unarmed and expired attempts, iframe non-capture, one-shot confirmation,
  lifecycle retirement and late completion.
- The settings and options suites cover disabled-by-default persistence and
  strict serialized types.
- The WebPanel widget matrix covers EN/TR at 600/1200 widths with 2x text,
  keyboard arming, explicit confirmation, exact one-time launch and replay
  denial.
- Focused result: 59 tests passed; scoped Flutter analysis, queue validation,
  formatting and `git diff --check` passed.

## Remaining K03 boundary

`intent:` URLs stay rejected. K03.remaining is not closed by this slice because
the documented Android WebView redirect and WebSocket enforcement gaps and the
physical Huawei/DeX/manual WebView acceptance gates remain. Queue and selected
feature counters therefore remain **26/125 (20.8%)** and **0/63 (0.0%)**.
