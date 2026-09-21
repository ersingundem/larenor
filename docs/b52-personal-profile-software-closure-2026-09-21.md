# B5.2 personal profile and sensitive-session software closure

The personal remote-profile Client/Core synchronization is merged on `main`.
This review closes the B5.2 software scope while keeping physical RDP, VNC and
SSH sessions, Huawei MatePad, Samsung DeX, keyboard and TalkBack checks in the
manual release matrix.

## Three acceptance criteria

| Criterion | Accepted behavior | Evidence |
| --- | --- | --- |
| Separate local and Core sources | Remote Access presents profiles stored on this tablet separately from Larenor Core profiles. Core data binds the exact Core, home, account, authenticated session family and collection revision; account replacement, sign-out, route loss, background and idle retirement clear authority. | 44/44 focused Flutter tests; EN/TR 320/600/1280 at 2x text; merged source `e313328f` |
| Conflict and uncertain-result recovery | Create, update and delete carry bounded request IDs and exact account, collection and row revisions. Conflicts become stale read-only rows until explicit refresh. Accepted mutations require verified full readback; lost responses are reconciled after restart without replay. | Controller request, 409, rollback, stale-readback and lost-response tests; independent source review |
| Closed private-state boundary | Core profile metadata allows only label, protocol, host, port, username and revision. Passwords, tokens, secrets, PINs and leases fail the parser and never enter diagnostics. The shared tablet surface preserves 48 dp actions, keyboard activation and live authority states. | Closed-model and request-body tests; PR #271 exact CI and security gates |

## Verification

The integrated branch passed **44/44** focused Flutter tests and scoped analysis
with no issue. EN/TR localization JSON, queue, security, commit-progress, diff
and secret scans passed. PR #271 exact CI then validated the merged Client,
Android artifact, API 35 journeys and unchanged Server/security boundaries.

Real remote hosts, physical tablets and live RDP/VNC/SSH sessions remain manual
release gates and are not inferred from fixtures.
