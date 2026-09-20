# F63 native SSH acceptance gate

## Scope

This gate reuses Larenor's production `DartSshEngine`, `DartSftpEngine`, and
`DartSshTunnelEngine`. It provisions an ephemeral loopback-only OpenSSH server
on a GitHub-hosted Ubuntu 24.04 runner. The server package is fixed to
`1:9.6p1-3ubuntu13.19` and asserted with `dpkg-query`; Flutter is fixed to
3.47.2 and every external action is pinned to a full commit SHA. No repository
secret, home server, or production credential is used.

## Three acceptance criteria

| Criterion | Automated evidence |
| --- | --- |
| Pinned encrypted terminal | A fresh Ed25519 host key and passphrase-encrypted Ed25519 client key perform a real SSH handshake. The Dart engine receives the exact runtime `ssh-ed25519` SHA-256 pin and rejects a different valid pin after one socket attempt. It opens an `xterm-256color` PTY, preserves `İstanbul` as UTF-8, sends explicit input, and proves a live resize to 132 by 43. An explicit reconnect creates a fresh engine and never replays the old line. The tablet surface still covers EN/TR, 600/1280 pixels, 2x text, 48 dp keyboard-reachable trust controls, and native focus retirement for DeX. |
| Bounded SFTP ownership | The production transport lists at most two entries and reports truncation, downloads a known file, uploads with exclusive-create semantics, round-trips its bytes, and rejects an over-limit write before transfer. A cancelled one MiB upload now removes the exclusively-created remote object; a retired read stops, and the controller revalidates the account/profile after every list or transfer before publishing state or saving bytes. Closing the owner waits for the SSH/SFTP connection to finish. |
| Fail-closed tunnel and replay boundary | A real loopback-only SSH tunnel reaches only the fixture HTTP endpoint. Authority is checked on both directions of every accepted connection, so a route/session loss closes the listener and active sockets before forwarding later bytes. Authority loss immediately after the local bind closes the unpublished listener, proven by rebinding the same port. Close completion waits for listener and server closure. Existing focused jump-host and MFA tests prove separate hop pins/credentials, one-shot challenges, and zero automatic command retry. |

RED `14011848` records the missing native workflow. GREEN `872aeaae` adds the
fixture, real protocol tests, workflow policy checks, and deterministic tunnel
close boundary. The adversarial follow-up also closes a credential/authority
race in password authentication and treats false or throwing tunnel ownership
callbacks as terminal without reconnecting.

## Verification

Local protocol verification used a disposable OpenSSH 10.3p1 loopback server:
all four native tests passed against the production engines. The combined
native/controller/tablet gate passed **51/51**. The adversarial RED run proved
that a cancelled upload left its remote object and that a profile replacement
could still save downloaded bytes; the GREEN run removes the owned partial and
rejects stale post-transfer results. The portable
focused gate also covers the controller and tablet panel suites, with the four
fixture tests explicitly skipped when fixture variables are absent. The workflow
policy has four passing checks and rejects floating actions, a floating OpenSSH
package, public binds, password/root login, unbounded sessions, or repository
secrets.

SSH uses the exact `dartssh2` 4.1.0 pure-Dart transport and therefore has no
separate JNI library to trust. The same gate builds a real Android arm64 debug
APK, inspects its `INTERNET` permission and Flutter arm64 host library, and fails
if an unreviewed SSH/crypto JNI shared object appears. This proves the Android
host packaging boundary without claiming that a Linux runner is a physical
Huawei or DeX device.

The authoritative Ubuntu OpenSSH 9.6p1 result must come from the new
`F63 SSH native acceptance` GitHub check on the exact PR head. Until that check
passes, F63 remains pending and progress stays at 17/125 and 0/63.

## Deliberately separate acceptance

Managed Core profiles still require the B3 authority chain before F63 can
close. Physical Huawei/DeX keyboard, network-change, background lifecycle, and
real household host checks remain under the manual tablet/features records.
No physical-device or production-host result is claimed here.
