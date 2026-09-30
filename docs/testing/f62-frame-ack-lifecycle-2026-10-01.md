# F62 frame ACK lifecycle — 2026-10-01

[Hosted run36789173329](https://github.com/ersingundem/larenor/actions/runs/36789173329)
at exact `7f673d55d059175a4bbbbfa213ddfc75e8b02651` built both native AAR/APK
lanes. Its original named x86 instrumentation executed once with zero skips,
one failure and zero errors. The safe source-bound diagnostic identifies
`RdpPackagedHostAcceptanceTest.kt:120`, the first frame acknowledgment. Actual
TLS/NLA/SPKI security and a nonzero 1280×800 frame had passed before that line.
The diagnostic alone does not identify the runtime failure code.

Production inspection and a deterministic regression reproduce a race: the
packaged ACK used to free its native pending-frame boundary before the session
had zeroized its previous buffer and returned to ACTIVE. A native graphics
callback could then publish the next frame into AWAITING_FRAME_ACK, closing the
session. The old ACK also wrote ACTIVE after a concurrent disconnect.

`RdpFrameDeliveryGate` now keeps the exact pending sequence after ACK. Only
consumer resume releases it; intervening updates coalesce into one fresh
frame. Wrong/repeated ACKs cannot release it and terminal gates never reopen.
Session state transitions use a private lock, while native I/O and observer
callbacks stay outside that lock. Disconnect/retirement during ACK returns
false and cannot resurrect or resume the session.

Root reproduced both old failures with the production session and an
early-release gate: two selected regressions failed. Restoring the fix passed
`RdpFreeRdpEngineTest` 7/7 and `RdpNativeContractTest` 7/7, zero skips/failures/
errors. The three added regressions cover graphics during ACK, wrong/repeated
ACK and disconnect during ACK. The production and original AndroidTest Kotlin
source sets compiled against the independently receipt-verified x86 AAR;
Gradle passed 314 tasks. The temporary AAR mount was removed afterward.

The safe failure artifact's package-receipt SHA-256 is
`c77414c97154a75e230ffcf77ecb61070dfe004d41e13fdc1c42bd78ca7d4c06`.
Both owned host packages were `3.32.0+dfsg-0ubuntu0.24.04.1`. No credentials,
certificates, pixels, raw JUnit or provider log were read or published.

These regressions prove the repaired local lifecycle; they do not replace a
new actual packaged-host receipt. A parallel capability review also found
unproved IME/bidirectional clipboard advertisement and a stale display
snapshot path. F62 remains open while those production paths are corrected
and real input/resize/clipboard/close acceptance is established.
