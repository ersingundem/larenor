# B5.1 server account tablet acceptance

## Scope

This independent B5.1 slice aligns the server connection, encrypted vault, and
server administrator surfaces with the shared tablet design and interaction
contract. The automated evidence targets Huawei MatePad class windows and
resizable DeX windows. Physical device, TalkBack, and live Core acceptance stay
outside this local widget-test evidence.

## Three acceptance criteria

| Criterion | Accepted behavior | Evidence |
| --- | --- | --- |
| Server connection | Sign-in and password-change fields expose IME Done, while primary, recovery, sign-out, administration, service, and plugin actions provide native button semantics and at least 48 dp targets. Enter runs the real sign-in action exactly once. Existing endpoint, account generation, session, route, lifecycle, and interaction-epoch checks continue to reject stale callbacks. Stored credentials remain distinct from a reachable service and a verified account response. | EN/TR, 600/1200 px, 200% text matrix plus sign-in, account replacement, background, idle, hidden-route, recovery, and navigation cases in `server_connection_screen_test.dart` |
| Encrypted vault | Review, direction, apply, and cancel controls use the shared surface and section hierarchy with native keyboard/TalkBack actions and explicit 48 dp minimum targets. Enter performs the read-only review and does not write. A mutation still requires a fresh review, exact account and revision authority, PIN authorization, visible route, and active lifecycle; conflicts never retry silently. | EN/TR, 600/1200 px, 200% text matrix plus conflict, privacy review, idle, route-cover, and hidden-dialog cases in `server_vault_screen_test.dart` |
| Server administration | Tabs, refresh, create, pagination, edit, password reset, revoke, and role choices provide at least 48 dp targets within the shared server administration surface. The create action has a localized semantic name and opens its real form with Enter. Admin generation, account authority, session, route, dialog, ticker, and lifecycle guards keep late or retained callbacks fail-closed. | EN/TR, 600/1200 px, 200% text matrix plus duplicate-submit, secret-draft, own-account, last-admin, session-revoke, background, idle, account replacement, and route-cover cases in `server_admin_screen_test.dart` |

## RED to GREEN evidence

- The RED matrix proved that all three primary actions left
  `CupertinoButton.minimumSize` unspecified. Their rendered height only reached
  48 dp incidentally under 200% text, so the contract failed independently on
  connection, vault, and administration.
- GREEN assigns explicit 48 dp minimums to the owned actions, connects IME Done
  to the guarded sign-in and password-change paths, and uses the shared action
  tile for server navigation without weakening the existing authority checks.
- The focused command covering all three criteria passed **64/64** tests:
  `flutter test test/features/server/server_connection_screen_test.dart test/features/server/server_vault_screen_test.dart test/features/server/server_admin_screen_test.dart`.
- Focused `flutter analyze` completed with no issues for the three production
  screens and their widget tests.

## Boundaries

The tests use local fakes and provider overrides. They do not contact a live
Larenor Core or persist real credentials. This slice does not claim physical
Huawei/DeX/TalkBack acceptance or close the remaining app-wide B5.1 visual
pass. Queue progress therefore remains **18/125** and selected-feature progress
remains **0/63**.
