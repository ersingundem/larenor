# VNC direct DNS/TCP boundary — 2026-09-11

This slice binds the explicit VNC profile host and port to a bounded Android
native DNS/TCP state contract. It does not enable production VNC networking.

## Implemented contract

- A numeric IPv4 or IPv6 target skips DNS and permits exactly one TCP attempt.
- A domain resolves to at most eight unique numeric addresses. The connector
  receives the deterministic first address and the explicit profile port.
- After TCP connection, domains are resolved once more. The full normalized
  address set must be unchanged and the reported peer must match the selected,
  pinned address. Drift fails closed and closes the connection.
- Unspecified, loopback, link-local, multicast, IPv4 reserved/broadcast, and
  equivalent IPv4-mapped IPv6 targets are rejected before use.
- The connector contract always sets `proxyAllowed=false`; proxy and environment
  configuration are not inputs to the raw VNC path.
- One total deadline, bounded to 30 seconds, covers lookup, connect, and
  revalidation. Timeout, backgrounding, explicit close, malformed results,
  lookup failure, and connection failure detach/cancel once.
- Late connections are immediately closed. No alternate-address attempt,
  automatic retry, restart, or replay exists.

## Deliberately unavailable

`VncDirectTcpSession.productionAvailable` remains `false`. The packaged native
backend remains unavailable. Resolver and connector interfaces are exercised
only with synthetic operations in this slice; no system DNS implementation,
socket implementation, credential/auth exchange, TLS bytes, RFB bytes,
framebuffer publication, or physical server acceptance is claimed.

The next acceptance slice must implement the owned Android resolver/direct
socket adapters with bounded execution and prove them against an isolated local
fixture before this state machine can feed the verified TLS/RFB boundary.

## Evidence

- Direct DNS/TCP contract: 6 focused tests passed.
- The complete Android VNC package and existing Flutter bridge/surface gates are
  run before delivery.
- Queue counters remain 14/125 and 0/63; F62 remains open.
