# F62 owned shadow cliprdr and DISP fixture foundation — 2026-10-01

This slice prepares an exact FreeRDP server fixture for the two production
client capabilities that the earlier owned shadow baseline did not expose:
client-to-remote clipboard and client display control. It is an
evidence-staged foundation. It does **not** by itself establish an Android
clipboard effect, a resized frame, or F62 acceptance.

## Immutable source and build boundary

The helper accepts only the FreeRDP `3.31.1` release asset at commit
`63b948ca5cb94307fd5444ee6e73927a41ccdab4`:

- source SHA-256:
  `4a2629026896cb4e26fb8ed2d6ca6aa4ab89ca95528dfbae2550c2f6bc866991`
- fixture patch SHA-256:
  `370c9c2f51c3bcf99c726534b60d22a8b695b303d1658cdedd8e5c3c2ac5d3e1`

The source archive, patch and patched files are opened without following a
final symlink, bounded, hashed through their opened descriptor and checked for
the expected owner/type/link count. Archive links, traversal, duplicate names,
oversized members and a changed source file fail closed. The helper applies
the already-verified patch bytes and verifies every patched output digest.

On Linux, `build` configures the pinned tree with the real X11 shadow
subsystem, server cliprdr, drdynvc and DISP, then builds the exact
`server/shadow/cli/freerdp-shadow-cli` target. Build output is private and the
result must be a nonempty executable owned by the current fixture user. The
existing TLS, NLA, SAM and SPKI configuration remains the responsibility of
the owned-host runner; this patch does not add a weaker authentication mode.
The fixture also binds the exact upstream `shadow_client.c` digest and frees
private channel state from `ContextFree` before the encoder and WTS manager
resources. This idempotent fallback covers successful PostConnect followed by
a later client-connect failure while leaving normal channel cleanup intact.

Primary source points used by the patch:

- [shadow authenticated-client channel lifecycle](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/server/shadow/shadow_client.c)
- [server cliprdr implementation](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/channels/cliprdr/server/cliprdr_main.c)
- [server DISP implementation](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/channels/disp/server/disp_main.c)
- [WinPR clipboard format synthesis](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/winpr/libwinpr/clipboard/clipboard.c)

## Exact private fixture contract

One pinned shadow process accepts exactly two authenticated PostConnect
contexts. Credential-free TCP/TLS probes do not reach PostConnect and do not
consume an ordinal.

1. Authenticated context 1 must have `cliprdr` joined. It receives the enabled
   witness path `${LARENOR_F62_CHANNEL_WITNESS}.1`.
2. Authenticated context 2 must not have `cliprdr` joined. It receives the
   disabled witness path `${LARENOR_F62_CHANNEL_WITNESS}.2`.
3. A third authenticated context is rejected.

Both contexts attach the real DISP dynamic channel. Context 1 requests the
actual offered synthesized `CF_UNICODETEXT` format. An initial well-formed
empty response is counted but never accepted as an effect. The terminal
clipboard effect requires an exact successful response containing the
explicit Android UTF-8 submission `Larenor-F62-İş-😀\n\tv1`, represented by
the protocol as UTF-16LE with CRLF normalization, the surrogate pair for 😀,
and a terminal WCHAR NUL. Combined or unknown response flags fail closed.

DISP accepts one primary monitor only, with left/top zero, the two configured
expected dimensions, physical width/height zero, landscape orientation and
desktop/device scale 100. These fields match the reviewed Android FreeRDP
client request. The fixture observes that exact request; it does not claim a
host resize or a resized frame.

The inherited private FIFO descriptor receives fixed eight-byte markers for
context 1 only. Their order is deterministic: `LRNDISP1`, then `LRNCLIP1`.
If clipboard arrives first, its marker waits for the DISP effect. This lets the
future owned-host runner causally apply and verify XRandR after the actual
client DISP request. Context 2 emits no phase markers.

Each terminal witness is an exclusive mode-0600 regular file of exactly 64
bytes. It contains only schema/magic, two effect bits and bounded event/error
counts. It never contains clipboard text, layout values, credentials or
pixels. The public parser opens it descriptor-first with `O_NOFOLLOW` and
requires current owner, one link, exact mode/size and zero reserved bytes.
Acceptance requires:

- context 1: exact clipboard and DISP effects with causal nonzero counters and
  zero channel errors;
- context 2: zero clipboard advertisements, requests, responses, empty
  responses and clipboard effect. DISP may still connect;
- no `${base}.3` witness.

## Local evidence and remaining gate

TDD began with import failure because the helper did not exist. The completed
focused suite passed **12/12** tests. It covers immutable preparation,
duplicate/archive-link/traversal rejection, patched-source symlinks, fixed
build arguments and executable output, private logging, witness owner/mode/
link/size/reserved/count bounds, causal effect validation, channel errors and
the enabled-then-disabled two-lifetime contract. It also locks the exact
`shadow_client.c` source and patched digests and verifies fallback channel
cleanup precedes encoder teardown. `py_compile` and scoped
`git diff --check` also passed. The exact patch was freshly applied to the
pinned release asset and every patched file matched the prepared source.

The local host is macOS. FreeRDP's own `server/CMakeLists.txt` disables the
shadow server there and reports `Mac shadow server implementation no longer
compiles`; the fixed target therefore does not exist locally. The bounded
private log was mode 0600 and showed that upstream platform decision followed
by `No rule to make target freerdp-shadow-cli`. This is not a Linux compile or
runtime receipt.

F62 remains open until a Linux owned-host gate builds and runs this exact
pinned CLI, keeps TLS/NLA/SAM/SPKI intact, drives the production Android client
through both authenticated contexts, verifies the supplementary Unicode
clipboard response, causally applies the observed DISP layout and obtains a
new frame, and validates the second context's zero-transfer clipboard policy.
No real text, layout, credentials, frame bytes or provider logs may enter the
public receipt.
