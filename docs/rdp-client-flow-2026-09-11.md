# Personal RDP Client flow — bounded software slice

11 September 2026. This slice is independent of Proxmox and Larenor Core. It
extends the device-personal Remote access profiles for direct IP, IPv6 or DNS
RDP targets and keeps the accepted queue counters at 14/125 and 0/63.

## Delivered software boundary

- A strict target retains the common host, port and user fields. RDP-only
  settings add an optional Windows domain and an independent RD Gateway host,
  port and user. Neither target nor gateway accepts a URL, embedded port,
  path, credentials, whitespace or control characters.
- Fit-window, native and fixed display modes; automatic, Turkish Q and US
  keyboard layouts; and disabled, device-to-remote or bidirectional clipboard
  policies are closed enums. Clipboard starts disabled. Audio and file channels
  remain disabled until their native capability and Android consent paths are
  implemented.
- Settings, certificate pin and optional NLA/gateway password records are
  profile-bound, versioned and bounded in Android secure storage. Passwords
  never enter the common profile JSON, settings JSON, status, logs or error
  text. Profile removal/revision change, corrupt storage or retired ownership
  fails closed.
- Connection is always user-started. TLS and SPKI SHA-256 pinning are required;
  the first certificate needs explicit trust and a changed certificate stops
  before authentication. NLA credential persistence is a separate explicit
  choice. A dropped session remains failed until the user presses Reconnect;
  no command, input, credential write or connection is retried automatically.
- The tablet/DeX surface forwards bounded normalized pointer events, 32-bit USB
  HID physical key events and bounded window resize requests after the secure
  session reaches connected state. Disconnect, PIN/idle, route, account,
  background, focus, PiP or provider ownership loss closes the channel and
  rejects late callbacks.

## Honest availability and remaining acceptance

`UnsupportedRdpEngine` remains the production default. It performs no DNS or
socket operation and cannot report a connected session. The strict engine,
store, controller, certificate/NLA flow and tablet surface are exercised by
synthetic fixtures; this is the integration boundary for a reviewed Android
FreeRDP/JNI package.

F62 is not accepted by this slice. Still required: packaged native FreeRDP
build provenance and ABI hardening; real Windows TLS/NLA and RD Gateway
handshake; decoded frame rendering; Turkish IME/dead-key and remote shortcut
matrix; clipboard consent with Android lifecycle; external-display/multi-
monitor negotiation; loss/reconnect soak; TalkBack and physical Huawei tablet
and Samsung DeX keyboard/mouse acceptance. Audio, RemoteApp, H.264/GFX, UDP,
file, microphone, smart-card, USB and printer redirection remain unavailable.
