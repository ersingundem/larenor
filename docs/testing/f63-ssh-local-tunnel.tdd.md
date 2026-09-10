# F63 SSH local tunnel TDD evidence

Date: 10 September 2026

This stacked F63 slice adds one explicit local port-forward profile per saved
SSH target. The profile is kept in Android secure storage, bound to the exact
SSH profile identity, and reuses the existing encrypted credential and pinned
host key.

Security boundaries:

- The listener address is fixed to `127.0.0.1`; public, wildcard, remote and
  SOCKS binds are not configurable.
- Local ports are limited to 1024–65535, destination ports to 1–65535, and the
  destination uses the existing normalized ASCII/IP host contract.
- At most eight local connections are accepted. Cancel, focus/lifecycle loss,
  SSH loss, profile replacement, or host-key mismatch closes the listener,
  active sockets, SSH channels and SSH client.
- Saving and loading never starts a network connection. Starting and retrying
  are separate user actions; there is no automatic restart or replay.

TDD checkpoints:

- `9ab6fcb`: RED because tunnel models, store methods, engine and controller did
  not exist.
- GREEN is supplied by the following implementation commit and its test output.

Validation:

```text
flutter test test/features/remote_access/ssh/ssh_tunnel_controller_test.dart test/features/remote_access/ssh/ssh_tunnel_panel_test.dart test/features/remote_access/ssh/ssh_security_store_test.dart
16 tests passed.

flutter analyze lib/features/remote_access/ssh lib/features/remote_access/presentation/remote_profiles_screen.dart test/features/remote_access/ssh/ssh_tunnel_controller_test.dart test/features/remote_access/ssh/ssh_tunnel_panel_test.dart test/features/remote_access/ssh/ssh_security_store_test.dart
No issues found.

flutter test test/features/remote_access
123 tests passed.
```

No live network behavior is claimed. A physical Android device and a dedicated
non-production SSH endpoint remain required to accept real bind, forwarding,
network-change and background lifecycle behavior. Full F63 acceptance also keeps
PTY behavior, Unicode and Turkish input, terminal tabs, MFA, jump-host support and
the isolated SSH test host open. F63 remains open, so progress stays at 14/125
(11.2%) and 0/63 (0.0%).
