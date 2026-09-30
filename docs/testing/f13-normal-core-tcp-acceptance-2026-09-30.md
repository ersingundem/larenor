# F13 normal Client, Core and egress acceptance

Date: 2026-09-30

This gate uses the production Flutter account, service and component-egress
controllers over TCP to a normal Core. The only provider double is an owned,
read-only Home Assistant-shaped HTTP server bound to the runner's RFC 1918
interface. It neither reaches nor changes a household service.

## Provider and address contract

Home Assistant documents authenticated `GET /api/config` as the configuration
identity route and includes both `version` and `components` in its JSON
response. The fixture implements only that request and rejects the wrong bearer
credential or path. Core's fixed adapter remains the code that chooses the
route and validates the reply:

- [Home Assistant REST API](https://developers.home-assistant.io/docs/api/rest/)
- [Python `socket.getaddrinfo`](https://docs.python.org/3/library/socket.html#socket.getaddrinfo)
- [IANA IPv4 special-purpose registry](https://www.iana.org/assignments/iana-ipv4-special-registry/)

The acceptance server deliberately does not bind loopback. F13 rejects
loopback, link-local, metadata, documentation and other special destinations;
the runner discovers one host-owned address in an IANA private-use range and
binds the fixture there. Core resolves and connects through its production
transport with the reviewed numeric pin. Redirects, proxies and retries remain
absent from that transport.

## Two process lifetimes

The `configure` lifetime signs in through the real Client, creates a Home
Assistant service, loads its empty policy, requests Core's bounded resolution
receipt, explicitly saves that exact grant and runs the real service check.
The owned server observes one authenticated `GET /api/config`; Client reads an
authenticated verification plus the attributed `policy_replaced`,
`dispatch_authorized` and `probe_completed` audit sequence.

The Core then stops. The `restart` lifetime reuses the same private data and
vault roots while its TCP listener receives a new port. Client revalidates its
persisted session, reloads the same service and encrypted policy, and completes
one more authenticated probe. It then replaces the policy with an empty grant
set. A later service check fails closed and the fixture's final exact call list
still contains only the two authorized GET requests.

No production defect was found in this path, so this slice adds acceptance
evidence only. Existing focused tests continue to own malformed DNS,
redirect/transport failures, authority changes during resolution, cancellation,
strict Client parsing, replay and lease-terminal behavior. Physical Home
Assistant, Proxmox and Keenetic LAN acceptance remains a manual deployment gate.

## Evidence

```text
cd server
uv run python tests/support/f13_flutter_acceptance.py
configure: 1 passed
restart: 1 passed
exact upstream calls: 2 authenticated GET /api/config

uv run pytest -q tests/test_component_egress.py \
  tests/test_component_egress_resolution.py \
  tests/test_component_egress_safety.py tests/test_service_probe_api.py
69 passed

cd ..
flutter test --no-pub test/features/server/server_component_egress_test.dart \
  test/features/server/server_component_egress_screen_test.dart \
  test/features/server/server_component_egress_normal_core_test.dart
13 passed, 1 environment-gated test skipped

flutter analyze --no-pub lib/features/server/component_egress \
  test/features/server/server_component_egress_test.dart \
  test/features/server/server_component_egress_screen_test.dart \
  test/features/server/server_component_egress_normal_core_test.dart
No issues found
```
