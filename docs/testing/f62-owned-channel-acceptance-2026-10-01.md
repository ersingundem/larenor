# F62 owned FreeRDP channel acceptance

This gate extends the existing packaged Android RDP test without changing its
single JUnit class/method identity. It uses the pinned, locally built FreeRDP
3.31.1 shadow fixture and two sequential authenticated Android lifetimes in one
owned process.

The host runner verifies the exact prepared-source tree with the pinned helper,
requires `RDP_ACCEPTANCE_SHADOW_SOURCE`, `RDP_ACCEPTANCE_SHADOW_BUILD`, and
`RDP_ACCEPTANCE_SHADOW_BINARY` to be canonical current-user-owned paths under
`RUNNER_TEMP`, and requires the binary to be the helper's exact build-relative
CLI path. It records the binary SHA-256 before launch and rechecks it after
launch. The runner starts that binary with the private `0600` SAM file under
`RUNNER_TEMP`. The process receives one nonblocking inherited pipe and one
absent private witness base. The patched server admits at most two authenticated
post-connect channel contexts:

1. The first context must negotiate CLIPRDR. Android proves NLA and the pinned
   certificate, renders and acknowledges the initial frame, sends the existing
   Key A press/release, submits one exact single-monitor DISP layout for
   `1024x768`, and observes the resulting nonzero frame. It then submits the
   bounded UTF-8 clipboard marker containing BMP Turkish characters, LF, a tab,
   and one supplementary-plane emoji through the production `clientToRemote`
   channel. The fixture requests `CF_UNICODETEXT`, verifies the exact UTF-16LE
   response after FreeRDP's CRLF normalization, and emits fixed private phase
   records only after the DISP and
   clipboard effects. The host changes a private X11 background marker only
   after the clipboard receipt, and Android requires and acknowledges the
   resulting changed framebuffer before closing.
2. The second context must negotiate no CLIPRDR channel. It still authenticates,
   renders, and acknowledges a fresh frame. Android's production session rejects
   a clipboard submission and wipes the caller bytes. The terminal server
   witness must report zero format lists, requests, responses, empty responses,
   channel errors, and clipboard effect for this context.

The terminal witness files are private `0600`, fixed 64-byte records written
with `O_EXCL|O_NOFOLLOW`. The runner accepts exactly `.1` and `.2`, rejects an
unsuffixed or third record, validates both with the source-locked parser, and
stops the exact owned process group on every exit. The public receipt contains
only source/package digests and the bounded conclusions: two authenticated
lifetimes, enabled client-to-remote clipboard effect, enabled DISP effect, and
zero disabled-session clipboard transfers. Raw clipboard bytes, SAM material,
provider logs, phase records, and terminal counters remain private.

The source-built shadow process writes only to a runner-drained private `0600`
log capped at 1 MiB inside the auto-removed witness directory. A failed run may
publish the single boolean `serverResizeRequested`, derived only from the pinned
shadow source's exact `resize requested (1024x768@<dpi>)` line. The raw line,
client identity, surrounding messages, and log file are never published. This
boolean separates a missing server-side resize request from a later framebuffer
delivery failure; it is diagnostic evidence and cannot make a failed run pass.

This software gate does not establish remote-to-client clipboard, IME, physical
keyboard hardware, a physical Windows host, DeX hardware, or Huawei desktop
mode. It becomes acceptance evidence only after the hosted workflow builds the
pinned patched shadow fixture, runs the real packaged Android test exactly once
with zero skips/failures/errors, and emits the source-bound public receipt.

The preceding exact source `d69cb0bdaecda35e5a7a927dc2f4cfd93ffe1a01`
failed [run 36801363639](https://github.com/ersingundem/larenor/actions/runs/36801363639)
at `resizedFrameWait`: the original named test ran once with one failure,
zero errors and zero skips. The arm64 package job passed. The bounded published
failure diagnostic identifies the original test class and fixed stage; it
does not establish any post-resize frame, clipboard effect or clean-close
acceptance. The new channel fixture and resize boolean must distinguish the
remaining cause in a changed-source run; they do not retroactively make that
failed source pass.

The updated Android application and AndroidTest source sets compiled against
the newly rebuilt Unicode package; all **24 RDP unit cases** passed with no
skips/errors/failures. Root's **105 Python checks**, workflow actionlint and
diff whitespace check passed. The prepared fixture patch SHA-256 is
`370c9c2f51c3bcf99c726534b60d22a8b695b303d1658cdedd8e5c3c2ac5d3e1`;
fresh exact-source patch preparation and independent channel cleanup review
passed. Linux fixture compilation and both real Android lifetimes still require
the hosted gate.
