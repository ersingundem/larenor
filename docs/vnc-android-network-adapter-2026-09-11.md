# Android VNC network adapter boundary — 2026-09-11

This slice supplies real Android/JVM resolver, direct `SocketChannel`, and
`SSLSocket` adapter implementations behind explicit dependency injection. It
does not enable the packaged VNC backend.

## Implemented

- `VncSystemDnsBackend` converts resolver answers directly to bounded numeric
  address values.
- `VncSystemSocketChannelFactory` opens one blocking channel to the chosen
  numeric peer with the remaining total deadline. It does not consume URLs,
  proxy selectors, environment variables, or alternate-address retries.
- The asynchronous adapter validates at most eight unique addresses, connects
  once, checks the actual peer, and performs an exact post-connect DNS-set
  comparison before TLS.
- Production policy rejects loopback, link-local, unspecified, multicast, and
  reserved targets. A separate dependency-injected fixture scope accepts only
  loopback addresses; it cannot reach LAN or public targets.
- `VncSystemTlsHandshaker` restricts the socket to TLS 1.3, enables the JVM
  `HTTPS` endpoint-identification algorithm, requires the exact server name and
  modern TLS 1.3 cipher, and compares SHA-256 SPKI bytes in constant time.
- The peer evidence contains only the bounded protocol/cipher and verified
  digest ownership required by the next VeNCrypt boundary. Certificate/SPKI
  scratch arrays are wiped.
- One scheduled deadline covers DNS, connect, DNS post-check, and TLS. Explicit
  cancel/background, timeout, failure, detached listener, and late completion
  close owned sockets without retry or replay.

## Evidence and limits

Focused tests use system DNS only for `localhost`, a real `SocketChannel` only
against an owned loopback `ServerSocket`, and an injected TLS socket fixture.
They do not reach a LAN or public host.

`VncAndroidNetworkAdapter.productionAvailable` remains `false`; the default
native backend remains unavailable. Credential/VNC-auth exchange, feeding TLS
bytes into the RFB engine, framebuffer/input publication, Android
instrumentation with a real TLS server, LAN acceptance, and physical
tablet/DeX acceptance remain open before production capability can be enabled.

Queue counters remain 14/125 and 0/63; F62 is not accepted by this slice.
