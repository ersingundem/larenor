# F60 bounded Moonlight pairing cancellation — 2026-10-01

## Production defect and boundary

Pinned Moonlight Android 12.2 deliberately disables the read timeout for the first `PairingManager.pair()` `getservercert` request. The production runtime previously retired only an `AtomicBoolean`; it did not retain or cancel the exact OkHttp call. A cancelled PIN prompt, expired Core grant, authority retirement, or runtime close could therefore leave the single pairing worker blocked indefinitely and prevent later operations.

The embed-v3 patch adds terminal, instance-local `NvHTTP.cancelPendingRequests()`. It retains each exact `Call` until the response body closes, cancels only calls belonging to that `NvHTTP` instance, and rejects future calls on that retired instance. It does not use OkHttp's global dispatcher and cannot cancel a successor runtime's client.

`MoonlightEmbeddedRuntime` now owns one `MoonlightPairingFlight` per pairing attempt. PIN cancellation, authority replacement/retirement, exact-session retirement, close, Core grant expiry, and the five-minute native maximum all fence that flight. An absolute monotonic deadline is checked at every provider boundary and immediately before private computer/registration/journal persistence, so a delayed main-looper timer cannot permit a post-expiry commit. A cancellation after provider dispatch remains a durable `unknown` receipt and is never replayed or reported as a successful cancellation.

If retirement races the PIN presenter return, the returned dialog is accepted only when the exact flight and pairing intent still own the prompt. Final persistence holds the exact flight fence and runtime authority check together; a cancelled or replaced generation cannot install actionable credentials or registration state.

## Immutable engine contract

- upstream commit: `b48494cb96bff23d8886c4775cc4f39a1075495d`
- engine revision: `moonlight-android-12.2-larenor-embed-v3`
- embed patch SHA-256: `85bfb0080400eff2bc05392b4ea1c05b2b72dc152cafea9716008ae2dd222e0d`
- reviewed upstream `NvHTTP.java` blob: `ccf1921ad3b172f9e3b1af249ef09bab8d255452`
- required API: public instance `com.limelight.nvstream.http.NvHTTP.cancelPendingRequests()V`
- candidate AAR SHA-256: `cdd17d087e86843970bd02f92ba05c10ba1d4c66970763f09e96bf77c9b208fb`
- candidate receipt SHA-256: `8f8bf685f8d968ed18eccd30ef0f92bafac23b323d632c8806eeaa1e4b275bcf`

The package verifier rejected the preceding embed-v2 AAR with `missing_engine_api`, then verified the fresh v3 AAR, both declared ABIs, exact patch/source receipt, and API descriptor.

## Focused evidence

Command, with the unrelated concurrent product-native receipt verifier excluded after it stopped the first invocation before Kotlin compilation:

```text
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
  ./android/gradlew -p android :app:testDebugUnitTest \
  --tests com.ersingundem.larenor.game.moonlight.MoonlightEmbeddedRuntimeTest \
  -x :app:verifyProductNativePackage --no-daemon --console=plain
```

Result: **40 tests, 0 failures, 0 errors, 0 skipped; BUILD SUCCESSFUL**. Private log: `/private/tmp/larenor-f60-cancel-focused/gradle-4.log`.

New regressions include:

- `stalledPairingRequestCancelsBoundedlyAndReleasesTheSingleWorkerQueue`: actual `PairingManager` `getservercert` request with no response, exact call cancellation, and queued-worker progress;
- `pairingCancellationRetainsCallThroughAStalledResponseBody`: headers arrive but the body remains stalled, proving the retained call is cancellable through body consumption;
- `pairingFlightCancelBeforeAttachCannotAffectSuccessor`: cancel-before-attach is terminal while a separate successor flight remains active;
- `pairingDeadlineUsesGrantExpiryAndNativeFiveMinuteMaximum` and `elapsedPairingDeadlineFencesPersistenceWithoutDrainingTheMainLooper`: exact grant/native bound and monotonic fail-closed persistence without timer delivery;
- `pairingDeadlineIsRecheckedAfterFlightLockDelayBeforePersistence`: an expiry reached while waiting for the flight fence is rechecked before persistence;
- `cancelledPairingFlightCannotCommitPrivateRegistration`: zero private persistence after the flight is fenced;
- packaged API and embed-v3 revision reflection checks.

This is a software cancellation and durability gate. It does not replace the separate owned-Sunshine discovery, pairing, rendered-frame, PCM-write, input, and disconnect acceptance, and it does not claim household-provider evidence.

## Independent integration checks

Root read the actual JUnit XML: **40 tests, 0 failures, 0 errors, 0 skipped**. Root also ran the live package/product tests (**14 passed**) and discovery/stream runner tests (**49 passed**). The current runner requires embed-v3; an embed-v2 receipt is rejected, and the verifier rejects an older AAR even when a synthetic v3 receipt claims the new cancellation API. These checks do not establish actual Sunshine streaming.

The exact Moonlight patch has a narrow Git whitespace attribute, matching the existing FreeRDP patch policy. This preserves literal upstream blank-line context without changing the reviewed patch digest or applying an exception to application source files.

The preceding hosted run [36811116354](https://github.com/ersingundem/larenor/actions/runs/36811116354) executed exact `36cbe3a1febc7964fcfe8f5f7c2f2701a23530f6` with **embed-v2**, not this new engine. Its canonical named stream test failed: **1 test, 1 failure, 0 errors, 0 skipped**, `pairingRegistration`, with the PIN bridge still `listening`. That fixed stage is before accepted payload parsing; it does not distinguish an absent reverse connection from blocked or rejected framing. The cancellation defect is source-proven, but it is not claimed as the exact cause of that hosted failure. The separate newline/EOF handoff was reproduced and repaired by the [real open-socket regression](f60-pin-newline-framing-2026-10-01.md); this remains a source-proven gap rather than the exclusive diagnosis of that historical failure.

Root then passed the combined current F60/gamepad/owned-host/discovery/stream/workflow/package/product/queue/progress suite: **165 passed**, including the new newline regression. The actual combined embed-v3 two-ABI APK passed all five root installed/product/Moonlight/FreeRDP verifiers, with SHA-256 `0294d421804e3483bcf7665c43efa9437ddff0ecff1a94aea6aef58d6e6f67b3`. The broad required-package JVM suite then passed **345 total = 343 passed + 2 explicit opt-in skips**, zero failures/errors, with 59 actual JUnit suites. [Actual distribution evidence](product-android-dual-native-actual-build-2026-10-01.md). Strict hosted Sunshine streaming remains pending.
