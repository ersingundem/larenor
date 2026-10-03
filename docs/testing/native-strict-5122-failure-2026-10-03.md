# Exact 5122 native acceptance failures — 2026-10-03

Both runs used commit `5122bc61fa67a2723751388b52a6e21404e94796`.
Neither was rerun. Their original single named instrumentation cases each
reported **1 test, 1 failure, 0 errors, 0 skips**. Root downloaded only the
bounded failure artifacts into mode-0700 private directories, checked their
single JSON member and exact source/named identity, and retained mode-0600
copies. Provider logs and secret values are not evidence in this document.

## Sunshine

[Run 37121179343](https://github.com/ersingundem/larenor/actions/runs/37121179343)
failed in `productionNsdPairCatalogTwoStreamLifetimesTouchStopDisconnectAndLocalRetirement`
at `firstStreamOutput`. The source-bound finite callback witness reports
`surfaceCreated`, `positiveSurfaceChanged`, `stageStarted`, `stageCompleted`,
and `stageFailed` true, with `connectionStarted` false. The PIN bridge reached
`pairedClientObserved`; the command held `leaseGameVisible` but timed out with
`unknown_effect` and no accepted native observation.

Artifact **11274220421** contains a 1,561-byte canonical receipt. Its SHA-256 is
`606cf18c1151f8acadd633595c4300f4b8dc5433b7edd0b50b104f1e42bfbe65`;
the ZIP SHA-256 is
`54424ce7ea8dda65985c2bc92da617f1ea7d5438436dc6587da7611b2825bc64`.

This is a failure before an observed completed connection. A separate
source-backed one-shot tone race after connection is being corrected; it is
not established as this failure's cause. The failed connection stage still
requires a closed diagnostic and source review. Real frame, PCM, input,
two-lifetime and teardown acceptance remains open.

## RDP

[Run 37121180943](https://github.com/ersingundem/larenor/actions/runs/37121180943)
completed the arm64 package job successfully. The x86 package/owned-host job
failed in `nlaShadowBaselineProvesPinnedFramesKeyEffectResizeAndCleanClose`.
The bounded test-body wrapper identifies `firstSessionOpen` and the fixed
throwable class `RdpNativeFailure`. The owned marker channel was available,
but its record was invalid and its writer unknown; the shadow process remained
live with no exit code and no requested resize.

Artifact **11273861293** contains a 1,519-byte canonical receipt. Its SHA-256 is
`504c747b041dd28761fb3cb0d15edff0fcbee5b5cef0ae0d008e50e6da6db258`;
the ZIP SHA-256 is
`7d6fefc388fa132220bf1b55342616a43faf91f28e0d9447670cffc2ff9f9637`.

The receipt does not identify the exact native failure code or sole cause.
Package/compile success does not substitute for TLS/NLA, frame, input,
display, clipboard and clean-close runtime acceptance. New schema-3 remote
audio development is a separate source change and is not accepted by this run.

F60 and F62 remain **reworking**. FINAL.FUNCTION remains active; accepted
counts remain **35/127 tasks (27.6%) and 3/63 selected features (4.8%)**.
