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
| Pinned encrypted terminal | A fresh Ed25519 host key and passphrase-encrypted Ed25519 client key perform a real SSH handshake. The Dart engine accepts only the exact runtime `ssh-ed25519` SHA-256 pin, opens an `xterm-256color` PTY, preserves `İstanbul` as UTF-8, and observes the requested 101 by 37 terminal size. |
| Bounded SFTP ownership | The production transport lists at most two entries and reports truncation, downloads a known file, uploads with exclusive-create semantics, round-trips its bytes, rejects an over-limit write before transfer, and aborts a one MiB read when ownership retires. Closing the owner waits for the SSH/SFTP connection to finish. |
| Fail-closed tunnel and replay boundary | A deliberately wrong host pin fails after one socket attempt. A real loopback-only SSH tunnel reaches only the fixture HTTP endpoint; close completion now waits for both listener and server closure, after which the port refuses connections. Existing focused session, SFTP, tunnel, jump-host, and MFA tests prove peer loss, late completion, cancellation, separate hop pins/credentials, one-shot challenges, and zero automatic command retry. |

RED `14011848` records the missing native workflow. GREEN `872aeaae` adds the
fixture, real protocol tests, workflow policy checks, and deterministic tunnel
close boundary.

## Verification

Local protocol verification used a disposable OpenSSH 10.3p1 loopback server:
all three native tests passed against the production engines. The portable
focused gate also passed 27 controller tests, with the three native tests
explicitly skipped when fixture variables are absent. The workflow policy has
three passing checks and rejects floating actions, a floating OpenSSH package,
public binds, password/root login, unbounded sessions, or repository secrets.

The authoritative Ubuntu OpenSSH 9.6p1 result must come from the new
`F63 SSH native acceptance` GitHub check on the exact PR head. Until that check
passes, F63 remains pending and progress stays at 17/125 and 0/63.

## Deliberately separate acceptance

Managed Core profiles still require the B3 authority chain before F63 can
close. Physical Huawei/DeX keyboard, network-change, background lifecycle, and
real household host checks remain under the manual tablet/features records.
No physical-device or production-host result is claimed here.
