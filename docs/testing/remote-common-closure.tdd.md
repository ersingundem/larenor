# REMOTE.COMMON acceptance closure

Date: 23 September 2026

Status: **software acceptance candidate; exact-head review and CI pending**

## Acceptance boundary

1. Device-personal SSH, SFTP, SSH-tunnel, RDP and VNC launches use the closed
   `PersonalSessionResource` policy. The memory-only lease is exact to the
   provider account, route identity, profile id and revision, resource, PIN,
   foreground/window/interaction state and a 15-minute maximum lifetime.
2. Profile input accepts bounded IPv4, IPv6 and ASCII DNS targets with a
   separate port. The versioned 32-profile/32-KiB secure-store envelope carries
   no password, private key, certificate exception or command. Host-key and
   certificate trust stay in protocol-specific secure records bound to the
   exact profile identity; changed identity fails closed.
3. PIN/idle, lifecycle, native focus/DeX focus, route replacement, provider
   replacement, profile revision and Core account authority changes retire the
   active lease. SSH, SFTP, tunnels, RDP and VNC close their owned resources;
   late input, modifiers, clipboard, transfer or command results cannot publish
   or replay. Clipboard, audio, files and similar channels remain disabled
   unless the protocol contract and current session explicitly enable them.

## RED and GREEN

The final cross-feature gap was a device-personal session that remained mounted
when `ServerAccountController` advanced its authority generation. A Core account
is still optional for creating and opening a personal profile, but signing in,
signing out, refreshing or replacing that authority must retire an already-open
sensitive session.

The widget journeys first failed with `SshTerminalPanel` still mounted after
`signOut()` and after a current authenticated action received `401` without
advancing the controller generation. `RemoteProfilesScreen` now observes both
the controller generation and the in-memory session identity, invalidates every
held action and session closure when either authority changes, and removes the
listener on disposal. The same personal profile remains in secure storage and
can be opened again through a fresh PIN/current-route lease.

## Evidence package

The final local package covers the whole `test/features/remote_access` tree,
including profile validation/storage/concurrency, common lease and tablet
matrix, SSH/SFTP/tunnel lifecycle, RDP/FreeRDP contract, VNC framebuffer/input,
Core-managed profile logout and uncertain-result behavior. Scoped Flutter
analysis, formatting, queue/security/progress policy and `git diff --check`
must also pass.

F61, F62 and F63 remain separate because their real target interoperability and
physical Huawei/DeX acceptance are protocol-specific. REMOTE.COMMON closes only
the shared profile, trust and session-lifecycle foundation. The queue stays at
**25/125** until this exact head passes independent review and required CI; the
closure commit will then record **26/125** and **0/63**.
