# F61/F62 Core-managed desktop authority acceptance — 2026-09-30

## Production boundary

Core-managed RDP and VNC profiles now use the same closed authority boundary as
Core-managed SSH. The device-secure records are namespaced by the normalized
Core endpoint, Core ID, home ID, account ID, token family and the exact public
profile digest. RDP stores the certificate pin, user-approved connection
settings and credential in separate records. VNC stores only its certificate
pin; the VNC password remains a one-use memory lease.

The namespace byte encoding is shared with SSH and has byte-for-byte digest
regressions for the established SSH v2 keys. Legacy v1 records are visible and
removable only from the device-local namespace. A Core source never imports,
reads, overwrites or deletes them. Every Core-managed store operation checks
the current profile authority before and after storage I/O. Authoritative Core
delete is followed by explicit exact-namespace cleanup; cleanup failure remains
visible and retryable without replaying the server DELETE.

The Core profile screen advertises one desktop action only for the matching
protocol. RDP requires a non-empty username. VNC permits an empty username,
matching RFB password authentication. The panels receive the scoped store from
the live Core authority rather than resolving the device-local provider. Core
profile drift, token-family/account replacement, logout, route loss or panel
owner change retires the authority and closes the session exactly once.

## Actual normal Core gate

The following command starts the normal Core application on a real loopback TCP
listener, signs a Flutter client in, creates an RDP profile, writes and reads its
scoped pin and credential, performs authoritative DELETE plus exact local
cleanup, creates a VNC profile with an empty username, writes and reads its
scoped pin, and proves logout retirement is one-shot and rejects a later read:

```text
server/.venv/bin/python \
  server/tests/support/core_managed_desktop_flutter_acceptance.py
00:00 +1: All tests passed!
```

The test contains no RDP or VNC engine fake. It proves the normal Core transport,
profile authority, encrypted device-store namespace, cleanup and retirement
conjunction. It deliberately does not claim protocol interoperability.

## Native protocol evidence remains separate

Actual protocol interoperability remains owned by the native acceptance gates:

- F61 drives the production Android VNC bridge against an independently
  packaged TigerVNC `X509Vnc` server.
- F62 builds the pinned FreeRDP AAR into the APK and drives the production
  Android client against an owned NLA FreeRDP shadow host.

At the time of this local gate, neither hosted native workflow had a new passing
receipt for the current combined source. The latest F61 run observed was
`36765832888` and failed; F62 run `36765836443` passed both AAR/APK lanes and booted the emulator,
but failed before instrumentation because per-line shell execution lost its
Android working directory. The command-context fix now has a new exact hosted
run pending; neither earlier result is real protocol acceptance.
Those gates must pass at their exact committed revision before the project can
claim real RDP/VNC interoperability. The normal-Core gate above is not a
substitute for them, and the native gates are not a substitute for Core
identity and revocation proof.

Physical Windows/RD Gateway behavior, physical tablet/DeX focus and long-lived
household network behavior remain manual device/provider gates. No household
endpoint or credential was used here.

Root independently repeated the actual normal Core TCP gate (1 passed) and the
changed namespace/store/authority/Core-tablet subset (34 passed, zero skips).
Scoped production analysis is clean. The separate fixture environment is not
replaced by a fake native engine and no household address was contacted.
