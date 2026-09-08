# S08.7 slice 1 — selected Core switch Client

8 September 2026. This is the bounded Client implementation of the first part of
`core-home-assistant-adapter-plan-2026-09-06.md`, not completion of S08.7.
The initial Client base is `cd961acb1586680f24ec00eead8f4d972520df4c`.
The final Client source/test checkpoint is
`027597fa55d8ad48174f160f46585d286459a1af` on
`codex/core-ha-switch-client`.

## Result and boundaries

An explicit action on a Core resource opens its typed switch observation. The
Core home does not initialize the adapter before that action. Refresh reads fresh
resource metadata and then the selected snapshot; missing access/state, errors,
offline responses and expiry remove the old switch projection. A 404 does not
claim that either permission loss or an absent link is the known cause.

The existing PIN-protected resource administration route has an additive binding
entry. An administrator selects an existing Core Home Assistant service and an
exact `switch.…` entity, reviews the concrete resource/service/entity/state, and
explicitly cancels or confirms. Confirmation consumes the local preview once.
A response whose outcome cannot be established exposes an explicit GET recovery;
there is no automatic POST replay. A successful binding confirms the link, not a
switch command or physical device result.

`commandAvailable` is accepted only as literal `false`. There is no command
adapter or command control, no Direct HA provider/credential/REST/WebSocket
fallback, no global router/account/HomeSessionScope change, and no persistent
Client snapshot cache. The resource WRITE ACL remains reserved for the later
command slice; old DTO `canWrite` is not a dispatch grant. Direct migration,
command receipts and physical/native acceptance remain outside this delivery.

## Ownership and freshness

Each mounted route creates a separate `CoreHaOwner` and provider/controller.
The handle is bound to its container, HomeSession/runtime identity, account
and home generation, interaction identity/epoch, PIN callback and native view.
Observed false/throw retires an old handle permanently. Route coverage closes
its read and clears fields; returning can make a fresh handle/read. Moving the
same keyed widget between containers cannot revive an old owner even when the
old container, account and home objects remain alive.

The controller uses the current verified account, rather than retained runtime
identity as authentication. It permits its own bounded account preparation to
complete, then checks exact session ownership around each API await. Retired
late 200/401 responses are cancelled before the shared account error boundary;
a current Core 401 still rejects the account. Upstream HA 502 errors do not
expire Core authentication. Resource/ACL revision floors survive failed reads.

The snapshot/preview deadlines use a monotonic clock captured before network
work, subtracting request duration from Server remaining TTL. Both callback and
getter checks reject expiry even before a delayed timer executes. If a dispatched
confirmation crosses its preview deadline, a late success or 401 is discarded
and its outcome remains uncertain; the still-current account is not rejected by
that expired operation. Server `observedAt` is informational, not Client expiry
authority. Permission changes are evaluated on explicit reads and known local
authority changes, not claimed as continuous push revocation.

## Actual contract provenance

The Server branch was merged without squashing: initial generated fixture
`359c3f3`, then final `422bca33c2c1648ba1b53fca3aa2d89b70ba381c` (reviewed
behavioral source `51c633a`). The Client did not edit Server files. The Server and
contracts trees equal that final Server checkpoint.

`contracts/home-assistant.v1.json` SHA-256:
`aeea76f3ebb149883bcd9adfbaf41275da0fc54ffd377a96b7f7e5022fa0e1da`.
Its exporter uses actual authenticated FastAPI/SQLite and seven loopback upstream
HA GETs. It captures **18** method/path/status/response entries. The final Dart
adapter parity test consumes all 18 and verifies exact method, path and body.
The earlier 33-test typed checkpoint consumed 17 selected entries; that historical
count is not relabeled. The Server owner's 448 related / 81 new test results are
separate evidence and were not rerun here.

The adapter reuses `LarenorServerApi` with its existing redirect/body/deadline
limits. The only shared transport change is exact HTTP-status/static-code
mapping for HA errors and `404/not_found`; legacy context-404 behavior and generic
proxy/mismatched errors have regressions. No new client or credential logging is
introduced. Binding IDs/revisions, schema/ref/context, 128-character ASCII entity
ID, 0–5000 ms snapshot TTL, 1–60000 ms preview TTL, literal-false capability and
exact preview/confirm equality are checked. Oversized responses hit the actual
shared transport bound.

## Runtime checkpoints

All checkpoints are preserved in branch history; no RED was inferred from a
compile failure. Counts below are separate runs, not additive unique totals.

| Boundary | RED | GREEN |
| --- | --- | --- |
| Strict model/API contracts | `639b33f`: 21 model and 10 API failures | `ce09784`: 33 tests |
| Mounted account/home controller | `da14ff4`: 3 pass / 17 fail | `4952a51`: 20 pass |
| Dispatched confirm crosses preview TTL, late 200/401 | `0eb6e41`: 2 fail | `1d491ba`: 22 controller pass |
| Actual Core/PIN screen entry | `04d4bd3`: 8 missing-entry failures | `ab4b5ef`: 8 UI pass |
| Expired snapshot before delayed timer | `9d9d490`: 1 fail | `f04b812`: 23 controller pass |
| Native Tab ring clipped in 320 px / 2x viewport | `89a9424`: 10 pass / 4 fail | `63afdb4`: 14 tablet pass |
| Expired preview before delayed timer | `27f93b7`: 1 fail | `8299e70`: 26 controller pass |

Fixture/measurement corrections are not product defects: initial entry lookup
before scrolling, an incorrect first/second preview response in a confirm fake,
a nonempty synthetic 204, a semantics-handle cleanup error, and a Finder compile
typo were corrected separately. The first final focused run was 105 pass / 4 fail
because an older test read a raw semantics node merged into its parent. The
corrected test measures the effective node (not merged into parent), exact button
label, single node and 48 px dimensions; all 109 focused tests then passed.
The real 320 px native focus regression remains distinct from these fixtures.

## Verification and tablet evidence

- Final focused run: **109 PASS**, 11 seconds, before braces-only lint cleanup.
- Final exact-source related run: **624 PASS**, 34 seconds reporter / 36.53
  seconds wall, on `027597f`. It includes the 109 focused tests; these counts
  are not added together. Existing resources, HomeSession, PIN/IdleGate, account,
  context, service and query/wire regressions passed.
- Analyzer: **5 input paths, 0 issues**. Formatter: **19 Dart files, 0 changed**
  after cleanup. Earlier lint output (braces and two unused test imports) remains
  preserved with the failed check receipts.
- Focused feature line coverage: **856/889 = 96.29%**. Final related-source coverage after braces cleanup: **857/890 = 96.29%**
  across the seven new feature files. No uncovered source was excluded.

Mounted widget tests use actual ConfigurationScope → HomeSessionScope →
LarenorApp, SettingsGate/PIN and ServerAccountController with bounded synthetic
HTTP. They cover source change, failed source write, logout, role change,
PIN loading/rotation, root-route coverage, window policy loading/error/PiP,
native focus/background, current versus retired 401, and actual GlobalKey
container reparenting. Direct credential/REST/WebSocket counters remain zero.
No real home endpoint or native emulator was used.

The real bundled-font matrix covers EN/TR, 320/600/1280 px, light/dark and 2x text.
It measures effective headings/buttons, 48 px targets, actual Tab/Shift-Tab and
Enter/Space actions, and painted focus outline contrast of at least 3:1 and full
viewport containment. These are widget/render evidence, not TalkBack, a physical
DeX device or a global default-size text contrast/design acceptance.

Private QA images were actually opened and inspected (wrap, focus and bounds):

- `/private/tmp/larenor-core-ha-client-qa/tr-600-dark-binding-2x.png`
- `/private/tmp/larenor-core-ha-client-qa/en-1280-light-binding-2x.png`
- `/private/tmp/larenor-core-ha-client-qa/tr-600-snapshot-2x.png`
- `/private/tmp/larenor-core-ha-client-qa/en-1280-snapshot-2x.png`

The synthetic resource/service names are fixture content. These images do not
replace the final public README gallery. No general emoji/font-fallback or
physical Home Assistant installation identity claim is made.

## Delivery evidence

Private receipt: `/private/tmp/larenor-core-ha-client-delivery-evidence.json`.
It records exact source/tree, hashes, commands, completed exit codes, focused and
related logs, LCOV and QA paths. All SDK commands were serialized through
`/private/tmp/larenor-flutter-check.py`; temporary `caffeinate -i` was bound to its
own runner. No main/queue/push/CI operation was performed. Android,
`integration_test`, `.github`, global core/auth/settings and the shared account
controller remain unchanged from the Client base. Whole Client/Server and native
CI acceptance are subsequent integration gates.
