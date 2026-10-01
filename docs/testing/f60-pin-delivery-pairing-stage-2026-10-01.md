# F60 bounded owned PIN delivery and pairing stages — 1 October 2026

The exact3feb723c28aa745445edcc770b27d9794b7e5b11 [owned Android stream run36808021320](https://github.com/ersingundem/larenor/actions/runs/36808021320) failed the canonical original test:1test,1failure,0errors,0skips. Owned frames99/680 identify the pairing callback wait (`pairingRegistration`). They do not identify which PIN/admin/cryptographic handshake substep stalled.

Independent source review found that the fixture `LoopbackPinPresenter` swallowed every socket exception and returned before its one-use PIN write completed. The [pinned official PairingManager source](https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/nvstream/http/PairingManager.java) deliberately disables the first server-certificate read timeout while waiting for provider PIN entry. An unnoticed delivery failure therefore permits a pairing wait without a useful fixture failure. This is a proven unsafe source path, not a proven exact cause of the old hosted failure.

The fixture now waits at most10seconds for its bounded one-use socket write. Failure or timeout stops before pairing dispatch with a fixed message and closes the active socket. The payload is cleared and no PIN, nonce, endpoint, certificate or provider reply is published. Completed local write does not itself prove host acceptance.

The private host bridge records only a fixed last-completed stage:
`listening`, `pinReceived`, `pendingPairingObserved`, `approvalInFlight`,
`approvalConfirmed`, `pairedClientObserved`. A failed run can attach that enum to the existing sanitized source/package-bound diagnostic. Injected or unknown values are rejected. Raw provider logs, errors and identifiers remain private. Diagnostic publication does not change the original test exit result.

Root independently passed `PYTHONPATH=. server/.venv/bin/python -m pytest tool/tests/f60_sunshine_android_stream_test.py --tb=no -q`:33passed,15subtests passed. The agent also completed actual `:app:compileDebugAndroidTestKotlin` with the required current dual-native installed package. These are source/fixture and compilation results, not stream acceptance.

The canonical success gate remains unchanged: actual discovery/cryptographic pairing/catalog, two stream lifetimes, rendered frame/full PCM output, host-observed input, stop/disconnect and local retirement/no replay. F60 remains reworking until that real gate passes. A next run must use the changed source; no unchanged-source retry is claimed.
