# F63 SSH terminal tabs and PTY TDD evidence

Date: 10 September 2026

This stacked F63 slice replaces the single terminal owner with at most four
tablet and DeX terminal tabs. Creating or selecting a tab never connects it.
Each tab exposes its own connection state and requires an explicit connect,
send and disconnect action while reusing the exact saved SSH profile,
encrypted credential and pinned host key.

The SSH shell requests an `xterm-256color` PTY. Initial and subsequent terminal
dimensions are bounded to 20–500 columns, 5–200 rows and 0–16384 pixels. Window
size changes are deduplicated and sent only to a connected, current tab. UTF-8
decoding remains streaming across byte boundaries and the input contract covers
Turkish text such as `İstanbul, çığ öşü` without lossy conversion.

Security and lifecycle boundaries:

- Four tabs is the product limit; the controller rejects unsafe configured
  limits above eight.
- Closing a tab, leaving the panel, app/window focus loss, profile replacement
  or disposal closes that tab's channel and engine resources.
- No tab connects automatically. There is no reconnect, command replay, startup
  command, tab restore or input forwarding between tabs.
- Host-key change continues to fail closed and cannot replace the saved pin from
  this screen.

TDD checkpoints:

- `4058efd`: RED because the tab owner, bounded PTY size contract, resize API and
  tablet tab controls did not exist.
- GREEN is supplied by the following implementation commit and its test output.

Validation:

```text
flutter test test/features/remote_access/ssh/ssh_engine_test.dart test/features/remote_access/ssh/ssh_session_controller_test.dart test/features/remote_access/ssh/ssh_terminal_tabs_controller_test.dart test/features/remote_access/ssh/ssh_terminal_panel_test.dart
34 tests passed.

flutter analyze lib/features/remote_access/ssh lib/features/remote_access/presentation/remote_profiles_screen.dart test/features/remote_access/ssh/ssh_engine_test.dart test/features/remote_access/ssh/ssh_session_controller_test.dart test/features/remote_access/ssh/ssh_terminal_tabs_controller_test.dart test/features/remote_access/ssh/ssh_terminal_panel_test.dart
No issues found.

flutter test test/features/remote_access
128 tests passed.
```

An isolated local OpenSSH fixture was attempted on the development Mac. Its
unprivileged daemon completed configuration and listen setup, then macOS blocked
authentication with `bsm_audit_session_setup: setaudit_addr failed: Operation
not permitted`. Docker is unavailable on that host, so this slice makes no live
handshake/authentication claim. A dedicated non-production SSH fixture remains
required for portable handshake, authentication, UTF-8, resize and disconnect
acceptance.

MFA and jump-host support remain open for full F63 acceptance. Progress stays at
14/125 (11.2%) and 0/63 (0.0%).
