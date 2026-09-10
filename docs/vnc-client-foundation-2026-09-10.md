# F61 VNC Android Client foundation

10 September 2026. This is a bounded, device-personal VNC readiness slice on
`codex/vnc-client-foundation`, based on `4925a504`. It does not mark F61 or any
selected feature complete.

## Delivered contract

The existing REMOTE.COMMON VNC host, port, label and optional username now open
an Android tablet/DeX readiness panel without requiring Larenor Core or
Proxmox. The panel calculates a bounded 640×480–8192×8192 display request,
limits it to 33,554,432 pixels and 72–640 DPI, identifies an external display,
and reserves touchpad and physical-keyboard input for the current foreground
session. Clipboard and file channels are visibly off by default.

The strict versioned contract accepts only RFB 3.8 with the initial reviewed
`vencrypt_tls_vnc_auth` selection. TLS transports require an exact
`spki-sha256` certificate pin. A first certificate needs an explicit user
decision; a changed pin fails closed. Unauthenticated and classic plaintext
VNC are explicitly rejected. Unknown fields, protocol/security values,
oversized displays, unsupported channels and malformed pins fail closed.

Passwords do not appear in `RemoteProfile`, `VncSessionRequest`, logs, trust
records or persistence. A submitted password is copied into a one-shot,
redacting byte lease, consumed at most once and zero-filled after the engine
call. The secure store persists only the certificate binding against the exact
REMOTE.COMMON profile hash. It does not silently replace an existing pin.

Each panel supports one bounded connection attempt. There is no automatic
retry or input replay. Background, loss of window focus, picture-in-picture,
PIN/idle lock, route replacement, provider/account replacement and sign-out
retire the attempt. Pending and late results cannot publish into a new owner;
owned channel and engine resources close once. English and Turkish status text
uses a live semantic region, 48dp actions, scalable text, and a tablet-width
content column.

## Honest native boundary

`UnsupportedVncEngine` is the product default. It returns an explicit
unavailable capability record from memory and its negotiate/open methods throw
`engine_unavailable`; it has no DNS or socket implementation. The connected
state is reachable only through a future injected engine that satisfies the
capability, negotiation, certificate and lifecycle contracts. This slice does
not draw a framebuffer or claim a successful VNC connection.

F61 remains open for a reviewed native RFB engine, real TLS/VeNCrypt and VNC
password handshakes, framebuffer rendering and bounded decoding, zoom/pan,
real input interoperability, SSH-tunnel policy, isolated test-host E2E,
Core-managed profile authorization, CI, and physical Huawei tablet/Samsung DeX
acceptance. Clipboard and file transfer remain unsupported.

## Focused evidence

- RED `582427f`: missing RFB models, engine and controller failed their focused
  contract tests.
- GREEN `76ecbdc`: 12 model/controller tests passed; scoped analysis and diff
  checks were clean.
- RED `40b5e00`: two widget journeys failed because no VNC action/panel existed.
- GREEN `ea9317d`: 16 model, lifecycle, trust-store and EN/TR 2× widget tests
  passed; scoped analysis and diff checks were clean.

Only focused VNC tests and scoped analysis are used for this slice. Broad
Flutter, CI, native-server and physical-device gates remain milestone work.
