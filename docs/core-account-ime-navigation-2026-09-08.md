# Core account form IME navigation — bounded local evidence

## Source and scope

- Worktree: `/private/tmp/larenor-core-account-ime-navigation`.
- Branch: `codex/core-account-ime-navigation`.
- Base: `960691c113b10e08ebddf75d464b99e74bdd4cb1`.
- Runtime RED: `f858f914baa844e813ed06a3e9db2eceb24740a9`.
- Minimal GREEN: `7dd3915aae5046ae277476e97438e7484e1c64bb`.
- Final source/test: `73e9bb60fda1fc901d544e4c71a3bf4fd9594f5a`
  (tree `da68c79d396a9cdd703d8363f4c050f499ab0219`).

Only `ServerConnectionScreen._field` and the administrator `_UserForm._field`
change. Their extra `onSubmitted` traversal callbacks are removed: four deleted
production lines in total. `textInputAction: TextInputAction.next` remains.
The pinned Flutter 3.47.2 `EditableTextState._finalizeEditing` already advances
focus for this action before invoking `onSubmitted` (local SDK
`packages/flutter/lib/src/widgets/editable_text.dart:3914–3962`).

The connection form consequently advances URL → username → password → device
name once per native Next event. The administrator create form retains its
existing username → first role button traversal; it does not skip the role
controls. Reset has one editable field: native traversal remains a single
request within its existing closed route/scope loop.

Field content, maxima, keyboard types, obscured passwords, autocomplete options,
enabled/submitted state, and all account/PIN/current/route/window/submit guards
are unchanged. There are no controller, API, layout, footer, modal, color,
localization, shared-helper, or integration-journey edits.

## Actual runtime proof

`test/features/server/server_account_ime_navigation_test.dart` mounts the real
`SettingsGateScreen(initialDestination: serverAccount)`. It verifies the PIN
screen first and unlocks it through its actual text-input action. Administrator
cases then open the real account → administrator route. They use the existing
`AdminFixture`, real `ServerAccountController` and `LarenorServerApi`, with all
HTTP ending in `MockClient`; no controller/UI stub or remote endpoint is used.

The first 12 tests cover login, create, and reset at EN/600/1x, TR/600/2x,
EN/1280/2x, and TR/1280/1x. Login checks actual editor primary focus; create
compares native Tab with native IME Next and verifies the existing first role
button. A reading-order policy observer delegates unchanged to the SDK policy
and counts only outer traversal requests, excluding recursive parent-scope
hops. This distinguishes one from two requests in reset's single-field loop.
Every IME operation preserves request counts and sends no authentication or
administrator mutation; password fields remain obscured and drafts preserved.

Twelve additional cases retain the actual native input client ID and the
enabled submit callback for login/create/reset, then cover the root route,
expire idle interaction, change the real PIN, or sign out the actual account.
They send `TextInputClient.performAction` to that captured client via the same
test binary-messenger seam used by Flutter's `TestTextInput`, followed by the
old submit callback. Channel errors are decoded and propagated. No subsequent
HTTP, administrator mutation, or session-store change occurs; closed secret
dialogs and PIN recovery remain asserted.

In the account-signout cases, the test explicitly unfocuses the field before
entering `runAsync` for the fixture's persistence queue. This avoids mixing a
fake-clock cursor timer with real-clock account work. These cases prove retired
account/submit authority and queued old-client behavior; they do not prove that
`signOut` itself disconnects a still-focused editor. The covered, idle, and PIN
cases retain focus until their actual lifecycle transition. Existing account
and screen guard tests remain part of the related regression run.

## Results (separate runs, not additive)

| Check | Result | Evidence under `/private/tmp/` |
| --- | --- | --- |
| Corrected runtime RED, original production | 0 PASS / 12 FAIL, 4.70 s wall | `larenor-account-ime-verified-red.log` |
| Minimal GREEN, same 12 tests | 12 PASS, 4.09 s wall | `larenor-account-ime-green.log` |
| Expanded completed matrix | 24 PASS, 5.04 s wall | `larenor-account-ime-complete.log` |
| 10 related files, including the 24 cases | 163 PASS, 590.02 s wall | `larenor-account-ime-related-final.log` |
| Final test-only analyzer cleanup | 24 PASS, 6.38 s wall | `larenor-account-ime-delta-test.log` |
| Final focused analyzer | 3 items, 0 issues | `larenor-account-ime-delta-analyze.log` |
| Final formatter check | 3 files, 0 changes | `larenor-account-ime-delta-format.log` |

The related set covers account/context/session storage, account screen,
administrator screen/controller, settings PIN gate/store, and IdleGate. Its
coverage reports `ServerConnectionScreen` 364/402 executable lines (90.55%) and
`ServerAdminScreen` 403/452 (89.16%). The LCOV file is
`/private/tmp/larenor-account-ime-final-coverage.info`. This is scoped local
coverage, not full-project or device evidence.

After the related run, the analyzer found two issues in the new test helper:
mutable scalar state on an immutable traversal policy and a public function
using a private harness type. The final test-only cleanup uses a final stack
for active calls and a private helper name. Final 24-test/analyzer/format
results above cover that delta; the two production callbacks did not change.

## Diagnostic limitations and process closure

Initial test setup attempts mixed fake-zone fixture creation with real-zone
account initialization and waited. An initial reset observer also counted
internal parent-scope delegation; its corrected outer-request oracle produced
the recorded 12 runtime failures before any production edit. A first late-IME
helper attempted direct channel-buffer delivery and waited; it was replaced
with the SDK's test messenger seam. These were test-fixture/measurement issues,
not additional product defects.

One completed intermediate expanded run was 23 PASS / 1 FAIL: executing a
focused editor's account transition wholly in `runAsync` left a real-zone
cursor callback after teardown. Directly awaiting the cross-zone queue was
also unsuitable. The explicit unfocus/real-queue boundary described above
resolved the fixture issue without changing production or mutation assertions.
All diagnostic logs and execution receipts are retained. Interrupted Flutter
processes returned zero after SIGINT; their receipts explicitly mark them
interrupted, never PASS. The related verification orchestration exited one
because of the two analyzer findings despite its test stage passing; the
final delta orchestration exited zero. Every owned process has been reaped.

All SDK commands used `/private/tmp/larenor-flutter-check.py`. The source is
frozen; no further SDK run, main merge, push, CI, emulator, real network/home
operation, or design expansion is included. This follow-up is separate from
the published base's CI/APK evidence and from the Services accessibility
packet. Parent integration/full Client and physical keyboard/IME acceptance
remain separate. Delivery receipt:
`/private/tmp/larenor-account-ime-delivery-evidence.json`.
