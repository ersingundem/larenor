# F62 Android FreeRDP microphone package evidence (2026-10-03)

## Scope

This slice adds two ordered source-locked patches after the existing certificate, clipboard, display/pointer, and remote-audio patches. `freerdp-always-pin-v4.patch` makes the Android client use application-managed X.509 verification for every target peer. `freerdp-microphone-v4.patch` observes the real pinned OpenSL ES AUDIN backend. The package identity is `freerdp-3.31.1-63b948ca-display-pointer-audio-microphone-v4`, JNI schema 4. No prior patch was modified.

This package work does not claim that a remote host heard audio, that a physical microphone is suitable, or that permission was granted. Those remain consumer and owned-host acceptance gates.

## Source contracts

FreeRDP's pinned Android configuration enables OpenSL ES, and `/microphone:sys:opensles` selects its AUDIN device. The capture backend is [audin_opensl_es.c](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/channels/audin/client/opensles/audin_opensl_es.c); AUDIN writes the `MSG_SNDIN_DATA` PDU in [audin_main.c](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/channels/audin/client/audin_main.c). Captured therefore means a nonempty recorder buffer callback. Accepted means the corresponding channel Data PDU write returned `CHANNEL_RC_OK`; codec negotiation or an empty encoder output does not increment it.

The pinned TLS implementation extracts full PEM before trust evaluation and invokes `VerifyX509Certificate` under `FreeRDP_ExternalCertificateManagement`; gateway transports are marked by `VERIFY_CERT_FLAG_GATEWAY`: [tls.c](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/libfreerdp/crypto/tls.c), [freerdp.h](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/include/freerdp/freerdp.h). The patch prevents the accepted-certificate and accepted-fingerprint caches from bypassing application-managed verification. The Android callback receives bounded PEM bytes, host, port, and flags; it accepts only an explicit positive consumer result and has no CA fallback or auto-accept path.

## Fixed microphone contract

`LibFreeRDP.EventListener.OnMicrophoneCapture(long instance, boolean deviceOpen, long capturedCount, long acceptedCount, int fixedState)` exposes only an exact-instance finite snapshot. Public constants are:

- `MICROPHONE_DEVICE_OPENED = 1`
- `MICROPHONE_BUFFER_CAPTURED = 2`
- `MICROPHONE_BUFFER_ACCEPTED = 3`
- `MICROPHONE_DEVICE_CLOSED = 4`
- `MICROPHONE_FAILED = 5`

The backend accepts only its existing PCM contract: 8- or 16-bit, one or two channels, at most 48 kHz. Buffer allocation is `frames * channels * bytes-per-sample`, checked for overflow, nonzero, and capped at 1 MiB. Counters are per plugin lifetime, monotonic, JavaScript-safe, and preserve `acceptedCount <= capturedCount`; violation or exhaustion is terminal failure. PCM is never published.

Close first marks the recorder closing, stops and clears the queue, destroys the recorder, waits at most five seconds for callbacks already in progress, securely wipes both capture buffers, and then releases the engine. `CLOSED` is published only after successful quiescence. Timeout publishes `FAILED` and retains the callback-owned graph rather than freeing memory still reachable by OpenSL.

## Verification

- `python3 tool/freerdp_android_package.py verify-lock`
- `python3 tool/freerdp_android_package.py verify-source <pinned-3.31.1-archive>`
- `python3 tool/freerdp_android_package.py verify-patch <prepared-v4-source>`
- `python3 -m unittest tool.tests.freerdp_android_package_test`

The verifier requires schema 4, both new ordered patch digests, exact reviewed upstream blobs, the compiled Java callback and five constants, `OnVerifyX509Certificate`, `OnMicrophoneCapture`, and the OpenSL AUDIN subsystem symbol in `libfreerdp-client3.so`. It rejects a schema-3 Java package and a package without the compiled AUDIN backend.

An isolated arm64-v8a build completed with Java 17, one Gradle worker and a 4 GiB heap. The actual AAR is `/private/tmp/larenor-f62-microphone-v4-final-20261003.9uEdCj/freeRDPCore-arm64-v8a.aar` (SHA-256 `9779d479ce4867fedaa9f5f4ea7812a12141eefa7afbf87ff973ab780dbf0c07`); its verified receipt is `/private/tmp/larenor-f62-microphone-v4-final-20261003.9uEdCj/receipt-arm64-v8a.json` (SHA-256 `18db9fda4b1189a7120e2cf4bb11c34331e5a1fba44ba988ace1948aae3312df`). A first compile correctly exposed that the new UI-listener pin callback needed a fail-closed default for upstream `SessionActivity`; the corrected source rebuilt successfully in 11 seconds (33 tasks, 17 executed) and passed `verify-install`. After pruning only disposable intermediates, the same verified source built x86_64 successfully in 1 minute 5 seconds (33 tasks, 28 executed). Its AAR is `/private/tmp/larenor-f62-microphone-v4-final-20261003.9uEdCj/freeRDPCore-x86_64.aar` (SHA-256 `885afa3921bdcf7df0c8d61dc8cb578cfe86c8cba0bd68cfe3f6184bbc5696a1`); its verified receipt SHA-256 is `f9a15e6eb47fa46cc0141edd7ed46e134d59531aba6eea4921de06ece03cc789`. Both receipts bind the same compiled classes SHA-256 `4107e7db2cdd59a0935e58425922406e4c7cf66eaef01670eccd03d9be89ddff`. `javap` independently confirmed `OnMicrophoneCapture(JZJJI)V`, the static X.509 callback `(J[BLjava/lang/String;JJ)I`, and the fail-closed listener descriptor `([BLjava/lang/String;JJ)I`. The producer did not mount an AAR into the shared application. Root subsequently composed, verified and mounted the pair and passed the actual product gates recorded in [composed evidence](f62-owned-microphone-composed-2026-10-03.md).
