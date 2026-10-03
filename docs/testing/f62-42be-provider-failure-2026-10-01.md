# F62 exact-42be owned-provider failure — 2026-10-01

The changed-source [strict run 36836063548](https://github.com/ersingundem/larenor/actions/runs/36836063548)
completed with failure at `42be601ed8182197252ecd0550a59411fc0cdab3`.
The arm64 package job `110283655375` passed. The x86_64 job
`110283655603` failed its real owned-host acceptance step. Its bounded failure
collector and owned cleanup completed; no acceptance override or rerun was used.

## Independently verified identity

- Active artifact: `11149613819`, named
  `freerdp-3.31.1-42be601ed8182197252ecd0550a59411fc0cdab3-failure-diagnostics`.
- Archive: 948 bytes; GitHub and downloaded SHA-256
  `5a978973a902ee6196be7480346809361ab1142a7a672915d06837cdd981135b`.
- Canonical JSON: 1,667 bytes; SHA-256
  `e2e3cc5a53724ac71fb082c10f96c0b1067d25668dda43305e787b0988dd2267`.
- Original test classification source:
  `6a1a13eb938e8c28efbff0f3b40edc2bec3a91661206fcfbd52b8c0a113ead05`.

Root downloaded and opened the record in a private mode-0700 directory with
mode-0600 files. Reconstructing the receipt through the production validator
produced the same closed record, and its bytes matched the canonical sorted
compact JSON plus one newline. Exact revision, source, package, fixture and
original named test identities were checked. Raw provider logs were not copied.

## Closed facts and remaining boundary

The original test count is **1 test / 1 failure / 0 errors / 0 skips**.
The failure is `initialFrameWait`, with allowlisted
`RdpOwnedInitialFrameConnectionFailed`, terminal `connectionFailed`, session
`failed`, and `resizeRequested=false`. The optional marker channel is available,
but its record is invalid and its writer is unknown.

The new failure-only observation is
`ownedShadowProcess={state:live,exitCode:null}`. It establishes that the owned
provider process was still alive at that poll before cleanup. It does not
establish which authentication, channel, native callback or transport boundary
failed. A live process is not a connected session or an accepted frame.

Both test sessions still require negotiated Unicode input. That assertion does
not prove a Unicode OS text effect on the owned X11 provider. The direct native
host test also does not exercise the Dart frame broadcast; the separately found
cold Dart initial-frame loss is a distinct software gap, not the proven cause of
this run.

F62 remains `reworking`. Its display/pointer/channel software work and original
TLS/NLA/SPKI/frame/ACK/input/DISP/clipboard/two-lifetime/close acceptance remain
open. The same source is not blindly rerun. Physical Windows/Huawei/DeX gates
remain manual evidence. [Previous observation implementation](f62-owned-shadow-channels-2026-10-01.md).
