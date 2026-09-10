# F63 SSH jump host and MFA TDD evidence

Date: 10 September 2026

This stacked slice adds one optional, explicit SSH jump hop to each terminal
attempt. The target and jump profiles retain independent normalized host/IP,
port and username values. Their encrypted credential references and host-key
pins are read separately; the target socket is opened through one
`direct-tcpip` channel owned by the authenticated jump client. A profile cannot
jump through itself and a second hop cannot be expressed.

Keyboard-interactive authentication is bounded to four server prompts. Names,
instructions and prompt labels reject control data and values above 1024 UTF-8
bytes. Answers allow at most 4096 UTF-8 bytes each, live only in the pending
one-shot completer, are cleared from the UI before submission, and are never
written to secure storage, transcripts, receipts or diagnostics.

Security and lifecycle boundaries:

- Creating/selecting a terminal tab or choosing a route never connects. The
  user explicitly starts every attempt and sends every command.
- One deadline covers profile checks, both credentials, both host-key decisions,
  both MFA exchanges, both SSH handshakes and PTY creation.
- Cancel, lifecycle retirement, stale generation, route replacement or either
  connection closing destroys target, forwarded channel, jump client and
  underlying socket without retry, reconnect or command replay.
- The tablet/DeX UI identifies target versus jump host during host-key and MFA
  decisions. Jump credential and changed-key errors use fixed secret-free text.

TDD checkpoints:

- `e50a528`: RED because one-hop routing and ephemeral keyboard-interactive
  challenge contracts did not exist.
- GREEN is supplied by the following implementation commit.

Validation:

```text
flutter test test/features/remote_access/ssh/ssh_engine_test.dart test/features/remote_access/ssh/ssh_session_controller_test.dart test/features/remote_access/ssh/ssh_terminal_tabs_controller_test.dart test/features/remote_access/ssh/ssh_terminal_panel_test.dart
37 tests passed.

flutter analyze lib/features/remote_access/ssh lib/features/remote_access/presentation/remote_profiles_screen.dart test/features/remote_access/ssh/ssh_engine_test.dart test/features/remote_access/ssh/ssh_session_controller_test.dart test/features/remote_access/ssh/ssh_terminal_tabs_controller_test.dart test/features/remote_access/ssh/ssh_terminal_panel_test.dart
No issues found.

flutter test test/features/remote_access
131 tests passed.
```

The macOS BSM restriction and unavailable Docker runtime recorded in the PTY
slice remain unchanged. No live jump-host or keyboard-interactive server result
is claimed. Full F63 acceptance still requires a dedicated non-production
fixture in CI or MANUAL validation for two independent host keys, both auth
stages, target-through-jump forwarding, challenge cancellation, network loss,
UTF-8, PTY resize and disconnect cleanup. Physical Android tablet/DeX lifecycle
and keyboard acceptance also remains open. Progress stays at 14/125 (11.2%) and
0/63 (0.0%).
