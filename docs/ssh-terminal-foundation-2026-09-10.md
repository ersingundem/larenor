# F63 SSH terminal foundation — personal Client profiles

Stacked on `7eab8882bf8a4e03275f5c30a18111673cfc5fd9`, branch
`codex/ssh-terminal-foundation`. This is a bounded F63 implementation, not full
SSH/SFTP/terminal acceptance. No live target, CI, push or PR was used here.

## User-visible behavior

A saved SSH profile with a username exposes an explicit SSH terminal entry in
the existing tablet Settings/PIN panel. Entering does not connect. The user can
save a password or PEM private key/passphrase in device secure storage, forget
that credential with cancel/confirmation, connect, inspect the server's key,
trust it explicitly on first connection, send one input line, and disconnect.
RDP/VNC remain metadata-only. No Core, HA or Proxmox account/transport is used.

The engine is pinned `dartssh2 4.1.0`, pure Dart with native Android-compatible
sockets. The package is MIT; its transitive additions and hashes are locked in
pubspec.lock. Existing Flutter package license registration is retained and the
notice index names the dependency. Official API/source:
https://pub.dev/packages/dartssh2/versions/4.1.0

This first terminal requests a `TERM=dumb`, 80x24 PTY shell and displays a
bounded plain-text transcript. It does not implement ANSI/VT screen emulation,
full-screen applications, dynamic PTY sizing, terminal key chords, SFTP, tunnels,
MFA/keyboard-interactive, agent forwarding, reconnect or command replay. Sending
requires an explicit button action; IME Done does not send. Disconnect closes
local resources and does not claim the remote process has stopped.

## Identity, secrets and lifecycle

The existing profile JSON remains unchanged and contains no secret. Separate
secure-store keys are derived from SHA-256 of the full canonical profile, so
host, port, username, profile ID or metadata edits do not reuse an earlier
credential or host pin. Secret and pin records carry the same target binding.
Every operation runs in ConfigurationWrites with current-owner checks before
and after awaits and actual profile revalidation. One complete secret record is
written and read back. Before/after-effect failures remain static and require
explicit inspection, never automatic mutation retry. No backup/Vault allowlist
or global secure-store clear/readAll was added.

These are FlutterSecureStorage references, not hardware-backed non-exportable
SSH signing keys. PEM/password material necessarily exists temporarily in Dart
memory for authentication; zeroization of immutable Dart strings is not claimed.
Forgetting credentials deletes only that target's credential; the trusted host
pin is retained. Profile edits/deletions do not automatically sweep old derived
secure keys; forget the credential before changing/removing a profile if its
stored secret should also be removed. Orphaned keys cannot authenticate another
profile. A device-wide credential inventory/cleanup is outside this slice.

Passwords are bounded to4096 UTF-8 bytes, PEM to32768, passphrase to1024. Key
parsing runs in a paused-then-owned isolate, killed on cancel or a3-second
limit, including expensive encrypted OpenSSH bcrypt inputs. Actual Ed25519,
RSA and ECDSA parse/transfer/signing tests exercise the maintained library.
Unsupported or invalid formats produce static errors without private material.

The engine preserves upstream cryptographic signature verification, awaits
explicit target-bound SHA256 host trust before authentication, and never enables
host-key verification bypass. A changed pinned key is blocked without an
overwrite option in this panel. First-trust text requires independent comparison
through a trusted channel. Pins never transfer to another profile/host/port/user.

TCP connect has a10-second limit; the controller bounds the complete attempt,
including trust/auth/shell setup, to45 seconds. Late sockets are destroyed.
Cancel, Settings/PIN generation loss, route/Ticker/container retirement, native
focus, window policy or app background retires the captured owner, closes the
socket/client/channel, clears the sensitive view and fences held callbacks.
Credential parser isolates are also cancelled. The controller never revives a
retired owner. Explicit reconnect starts a new attempt with no old input.

Both output streams are incrementally UTF-8 decoded; control characters are
rendered inert, with no OSC clipboard/link interpretation. Transcript storage is
bounded to65536 UTF-16 units. A normal channel exit waits for both streams to
drain, preserving final output. Errors close immediately with static failure.
Each explicit input revalidates the saved profile, permits at most4096 UTF-8
bytes and rejects multiline/control input. Transcript persistence is absent;
manual text selection is user initiated.

## Evidence and limits

- `5b83727`:8 actual secure platform runtime REDs, then8 GREEN.
- `fbcc78a`:12 controller runtime REDs. The first follow-up had11 PASS and
  one fixture assumption about stdout/stderr ordering; the streams have no
  shared order. The test now checks split UTF-8 before adding stderr.
- `c2154c7`: actual Settings/PIN entry RED. Missing SelectableText import and a
  test-only setIdle method name were compile mistakes, not runtime product bugs.
- Parser:12 actual RED→12 GREEN,94.9% parser-only line coverage.
- Independent source review found final-output drain and passphrase-byte
  mismatches:19 PASS/2 actual RED, fixed without weakening oracles. It also
  prompted callback-level host rejection capture and fixed engine completion
  errors, because the library wraps host callback exceptions internally.
- Real DartSshEngine with owned controllable SSHSocket:6 PASS for malformed
  handshake/EOF, current checks, pending-socket cancel/late destruction and
  parser cancellation. No live socket/network was used by these tests.
- Actual Settings/PIN UI covers storage, trust/cancel, input, disconnect,
  credential deletion and immediate native-focus/idle retirement. EN/TR600 and
  1280 at2x exercise native Tab/Enter and48px action geometry. Initial leaked
  SemanticsHandle fixture teardown was corrected; all action assertions already
  passed. Physical TalkBack, Android keyboard/DeX and visual PNG acceptance are
  not claimed.
- Final single related gate: **270 PASS, 25 seconds**; analyzer **2 items,0 issues**.
  New SSH files line coverage: **627/724 = 86.60%**.
  Final results and exact source/tree are in the private delivery receipt. The
  focused49 cases are included in the single related gate, not added to it.

Positive authenticated SSH handshake/shell interoperability on a real SSH test
server, physical Android secure storage and device lifecycle acceptance remain
unverified. The real engine is wired into production, but controller/widget
success uses an injected engine; those tests are not presented as wire-level
SSH success. Full F63 and REMOTE.COMMON remain open.
