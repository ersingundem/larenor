# Exact 9551 native acceptance failures — 2026-10-03

Both original runs used `9551e73782fdfcfb4a1308e1d01522858ec8d494` and
completed unsuccessfully. Neither run was restarted. Each original named
instrumentation case reports **1 test, 1 failure, 0 errors, 0 skips**. Root
verified the canonical JSON, source/named identity, original production
validator and SHA-256 of both bounded artifacts in private 0700 directories.
Raw provider logs, session keys and credentials are not published.

## Sunshine

[Run 37123578040](https://github.com/ersingundem/larenor/actions/runs/37123578040)
failed at `firstStreamOutput`. Its closed connection witness identifies
`rtspHandshake`, `transportPortsAndReportedCode`, and `connectionStarted=false`.
Pairing reached `pairedClientObserved`; the game lease existed, then stream
dispatch timed out with `unknown_effect`.

Artifact **11274304008** is 1,640 canonical bytes, SHA-256
`c1b5c161787e12f98969d9b1ab879efa626f8cd1d792d265c33896e4d5101db1`.
ZIP SHA-256:
`3e785580d845252c2620bae6a236377145653dd5344b7a1425db0c312899290e`.

Source review found a real composition defect: the normal launch sends RI
encryption key A, while the streaming Activity creates key B for resume.
[Pinned Moonlight NvConnection](https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/nvstream/NvConnection.java#L52-L66)
generates the new key. [Pinned Sunshine RTSP](https://github.com/LizardByte/Sunshine/blob/v2026.914.233613/src/rtsp.cpp#L545-L613)
retains its first pending launch instead of replacing it, and verifies
encrypted RTSP with that retained key. This source composition explains the
observed handshake boundary; a repaired source still needs real hosted frame,
nonzero PCM, input, two-lifetime and teardown acceptance. Fixed transport-port
flags alone do not establish a firewall failure. The repair preserves RTSP
encryption and provider app state, and will bind a single-use private key to
the exact launch/stream authority.

## RDP

[Run 37123504468](https://github.com/ersingundem/larenor/actions/runs/37123504468)
passed arm64 packaging. Its x86 owned-host case failed at `testBody`, with
`firstSessionOpen` and `RdpNativeFailure`. The source-bound provider process
was live with no requested resize. The marker channel was available, but its
record was invalid and its writer unknown; no open-boundary facts survived.

Artifact **11274533856** is 1,605 canonical bytes, SHA-256
`0ece0a2196d4810eace0b551fd65775ae448c60c78c97ddce5c1959e5f4d8d5a`.
ZIP SHA-256:
`6ded5917ee6fa61e96170350baae1f1db36dd094b3bd0aecc82302ed46c543c4`.
Root replayed the original validator against the original AndroidTest source,
SHA-256 `d757674537550dc871bb8a428ba684f209908bdbf3354036d7b11e24f880afb0`.

The live reader made any invalid read permanently sticky. A concurrent
incomplete storage read could therefore hide a later complete failure marker.
This is a source-supported diagnostic race consistent with the receipt; the
artifact does not prove it was the sole failure cause. The narrow repair
allows a complete live marker to replace an incomplete read, while a final
malformed record and contradictions between complete failure facts still
reject publication. The original failing test and all acceptance gates remain
mandatory. TLS/NLA and actual session success remain unproven.

F60/F62 remain **reworking**, FINAL.FUNCTION remains active, and accepted
counts remain **35/127 tasks (27.6%) and 3/63 selected features (4.8%)**.
