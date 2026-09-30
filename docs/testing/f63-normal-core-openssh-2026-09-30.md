# F63 normal Core and OpenSSH acceptance

Date: 30 September 2026

## Protocol boundary

- [RFC 4252](https://datatracker.ietf.org/doc/html/rfc4252) defines the SSH
  authentication protocol. [RFC 4256](https://datatracker.ietf.org/doc/html/rfc4256)
  defines keyboard-interactive authentication without assigning meaning to the
  prompts or answers.
- [RFC 4254](https://datatracker.ietf.org/doc/html/rfc4254) defines PTY requests,
  terminal resize messages and `direct-tcpip` channels used by the jump and
  local-forward paths.
- The pinned [`dartssh2` source](https://github.com/TerminalStudio/dartssh2)
  documents password, private-key and interactive authentication, shells,
  forwarding and SFTP. Larenor pins `dartssh2` 4.1.0 in its lockfile.
- The OpenSSH [`sshd_config`](https://man.openbsd.org/sshd_config) contract says
  every comma-separated method in an `AuthenticationMethods` list must succeed
  and documents the `local` forwarding restriction.

## Production repair

Core-managed SSH profiles now have a usable connection path. Before exposing a
terminal, SFTP browser or loopback tunnel, the Client re-reads the bounded Core
profile collection and binds the exact Core/home, account, session family,
account revision, collection revision, profile id, profile revision and public
connection fields. The same guard protects device-secure credential and pin
operations. A bounded three-second poll retires an otherwise idle live transport
when server-side authority changes. Account replacement, logout, route loss and
profile drift retire immediately or at the next guarded I/O/poll; none reconnect
or replay a command.

Device-secure credential, host-pin and tunnel records now use a v2 namespace
derived from the non-secret source kind, normalized Core endpoint, Core/home,
account, session family and exact public-profile digest. The digest is present in
both the storage key and sealed payload. An identical public profile from another
Core, account, token family or the local-profile source cannot read or delete the
record. Only the local source may read a legacy v1 key; its next explicit write
moves that record into the local v2 namespace. A confirmed Core profile deletion
removes credential, pin and tunnel records for only that exact namespace.

The real gate exposed a production type failure hidden by list-backed fakes:
`dartssh2` emits `Uint8List` terminal chunks, while the controller applied an
invariant `Utf8Decoder` transformer to the covariant stream. The controller now
casts chunks to their declared `List<int>` boundary before decoding. Strict UTF-8,
bounded transcript sanitization and Turkish text remain unchanged.

## Actual automated evidence

`server/tests/support/f63_flutter_acceptance.py` runs the production Flutter
Client through two normal installed Core/Uvicorn TCP lifetimes and one disposable
loopback OpenSSH 10.3p1 server. A fresh encrypted Ed25519 client key and a fresh
host key perform the real handshake. The first Client lifetime creates and opens
the Core-managed profile, opens a real SFTP subsystem and lists the bounded fixture
directory, then opens a loopback-only SSH tunnel and reads the exact fixture HTTP
body. It writes `profile-drift` once, then a Core profile revision change retires
the shell, SFTP transport and tunnel together. After Core restart, the stored
authenticated session is revalidated and all three transports open again. It
writes `session-revoke` once, and an actual logout retires all three. The owned
command log must contain exactly those two lines in order; no transport reconnects
or replays an operation.

A third actual Client phase logs in to the normal Core, sends the exact profile
DELETE, verifies the profile is absent, observes a typed secure-store deletion
failure, and explicitly retries only that exact namespace. The server receives
one DELETE; local retry does not recreate a remote mutation or SSH command.
The Client now allows only the canonical DELETE route and its four exact request
and revision query parameters; foreign, extra, prequeried/duplicate and
noncanonical revision values fail before transport. UI cleanup failure stays
visible, and pre-connect authority failure is visible in both EN and TR rather
than silently returning from the open action.

The Linux workflow extends the disposable fixture to three loopback-only OpenSSH
daemons. It exercises password authentication, encrypted-key authentication,
public-key plus PAM keyboard-interactive MFA, independent jump/target host keys,
target-through-jump `direct-tcpip`, PTY resize and Turkish UTF-8, bounded SFTP,
and a loopback-only tunnel. The daemons disable root login, agent/X11 forwarding
and kernel tunnels; the MFA daemon also disables forwarding. Workflow policy
tests pin Ubuntu, OpenSSH, Flutter and every external action.

## Evidence and remaining boundary

Local evidence on this host:

```text
normal Core TCP -> Flutter Client -> OpenSSH, two Core lifetimes: 2/2 passed
normal Core login -> DELETE/readback -> failed exact local cleanup -> explicit retry: passed
Core-managed SFTP listing and loopback HTTP tunnel in both lifetimes: passed
profile drift and logout retire shell, SFTP and tunnel together: passed
owned command receipt: profile-drift, session-revoke exactly once each
OpenSSH direct encrypted-key PTY/Turkish/resize gate: passed
security namespace, authority and transport-controller regressions: 46/46 passed
complete local SSH feature directory: 93 passed, 6 explicit fixture skips
root final transport/authority/security/tablet subset: 24 passed, zero skips
scoped production analyze: no issues
workflow policy: 5/5 passed
```

The local macOS fixture cannot safely provision a disposable password/PAM user,
so password, keyboard-interactive MFA and two-daemon jump interoperability require
the exact-head `F63 SSH native acceptance` Linux job. The test and bounded fixture
are present, but this document does not claim that unexecuted Linux result.
Physical Huawei/DeX keyboard and lifecycle behavior and real user-selected SSH
servers remain manual gates. No household endpoint or credential was used.

## Exact Linux MFA failure and standards repair

[Run 36765828318](https://github.com/ersingundem/larenor/actions/runs/36765828318)
at `b76558c4ee09b3f8e5fad4b274ac699576e71821` passed the encrypted-key,
PTY/SFTP/tunnel paths but failed the combined password/MFA/jump case. The owned
sshd diagnostic reached partial public-key success and keyboard-interactive PAM,
then the Client closed before authentication completed. The production Client
rejected zero-prompt informational rounds; the fixture also assumed every round
contained exactly one prompt. This is a protocol defect, not a reason to repeat
the same job unchanged.

[RFC 4256 sections 3.2–3.4](https://www.rfc-editor.org/rfc/rfc4256#section-3.2)
permit zero prompts, require a zero-response message in that case, and permit
empty user responses. The Client now validates bounded name/instruction text,
preserves the visible explicit-confirmation flow for informational rounds, and
returns exactly the confirmed response count. Host trust, authority/currentness,
length/control-character bounds and cancellation remain enforced. Empty answer
strings are accepted only as user responses, without storage.

Password, MFA and jump are now separate named real-protocol tests, so a failed
phase cannot obscure the other paths. The PAM case requires one password prompt
and at least one zero-prompt round. Root ran 43 focused engine/controller/UI tests
with zero skips and scoped analyze with no issues. The new exact Linux result is
still required; the local result does not establish password/PAM interoperability.

## Exact hosted runner failure after the protocol repair

[Run 36767901119](https://github.com/ersingundem/larenor/actions/runs/36767901119)
at `8159c9a72f47f2c8e3c5037a5a7933c96771d17b` completed the real SSH fixture
step, then failed before normal-Core acceptance with shell exit 127 because
`uv` was not installed on the hosted runner. No SSH, authentication or product
assertion failed in that step. Repeating the same run would not test the RFC
4256 repair.

The workflow now installs official `astral-sh/setup-uv` v10.2.0 by immutable
commit, pins uv 0.12.12 and verifies by policy test that setup precedes the
locked normal-Core runner. The exact-head hosted result remains required; this
workflow repair is not itself Linux SSH interoperability evidence.

Local regression evidence after this repair is 6/6 workflow-policy tests and
45/45 focused engine/controller/terminal tests, with scoped analysis clean.

## Hosted prerequisite and receipt hardening

The hosted workflow now pins Temurin 17 before Flutter and asks the immutable
setup-uv action for Python 3.12 as well as uv 0.12.12. The real OpenSSH fixture
is executed separately through `tool/f63_openssh_acceptance.py`. That runner
preflights every named fixture input without printing its value, consumes a
bounded Flutter JSON event report, and writes a receipt only when the exact
seven named tests complete successfully with zero skips or errors. The
workflow uploads only that non-secret receipt as
`f63-openssh-<exact commit>`. It does not upload the raw event report, fixture
logs, keys or credentials. The remaining controller and panel regressions run
only after that receipt gate.

This closes a false-pass path in which Flutter reports exit zero when all seven
fixture tests are skipped because their environment is absent. It does not
replace the already observed real execution in run 36767901119, and it does not
claim a new exact-head CI pass before one occurs.

Local readiness evidence is 12/12 helper and workflow-policy tests, 45/45
focused engine/controller/terminal tests, Python compilation, scoped Flutter
analysis and diff validation. The parser also rejected the actual JSON emitted
by a local missing-environment Flutter run because all seven named tests were
marked skipped. The hosted Temurin/Python setup and strict receipt still require
a new exact-head workflow result.
