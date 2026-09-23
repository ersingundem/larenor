# F13 Core component-egress DNS review TDD evidence

Date: 2026-09-23

The Android policy editor previously required administrators to discover IP
pins outside Larenor. This slice adds a read-only Core review endpoint that
returns the exact candidate grant for the selected service revision. F13 and
both progress counters remain pending until the Client consumes this receipt
and real LAN acceptance is complete.

## Three guarantees

1. **Bounded resolution without a connection.** Core resolves only the saved
   host and port, through two process-wide slots and a three-second ceiling.
   It accepts at most eight unique canonical stream addresses, classifies each
   through the existing LAN/public policy, and rejects partial, malformed,
   metadata, link-local or excessive results. A literal address performs no
   DNS lookup. No socket is opened and no credential is read.
2. **Exact authority.** The request carries the selected service revision.
   Core checks administrator authority and the supported service kind before
   DNS, then rechecks the complete private connection record after DNS. A
   concurrent endpoint, credential or revision change discards every answer.
3. **Secret-free transient receipt.** The schema-v1 response contains only the
   exact service/component binding and a validated candidate grant. Resolution
   does not update policy or persist addresses. Resolver failures and timeouts
   collapse to one static error without raw host, OS or exception details.

## RED to GREEN evidence

The RED checkpoint `2ecfe12d` added the endpoint, literal, revision-race,
bounded-failure and authorization matrix; all cases returned 404 before the
contract existed. GREEN passes that matrix together with the existing F13
policy and network-race suites.

```text
cd server
uv run pytest -q tests/test_component_egress_resolution.py \
  tests/test_component_egress.py tests/test_component_egress_safety.py
48 passed
```

## Remaining F13 gates

The Client must request and visibly review this receipt before saving pins.
Final acceptance still requires Home Assistant, Proxmox and Keenetic routes on
the target LAN and evidence that DNS changes are rejected before credentials
or commands leave Core.
