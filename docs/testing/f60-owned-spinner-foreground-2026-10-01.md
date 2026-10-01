# F60 owned connection spinner and foreground lease — 1 October 2026

## Reproduced local defect

Pinned Moonlight Game opens its own modal connection spinner in `onCreate`,
and dismisses it in `connectionStarted`. Larenor previously required Activity
window focus to claim the foreground lease; its `connectionStarted` callback
requires that lease first. The owned spinner can therefore prevent the claim
that would allow its own dismissal.

Sources: the pinned upstream [Game activity](https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/Game.java)
and [SpinnerDialog](https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/utils/SpinnerDialog.java).
Android documents the authoritative [top-resumed callback](https://developer.android.com/reference/android/app/Activity#onTopResumedActivityChanged(boolean))
for multi-resume starting at API 29.

## Repair and ownership boundary

Larenor now claims only a resumed, attached, shown Activity that is neither
finishing nor destroyed. API 29 and later additionally require top-resumed
ownership. Its own modal spinner does not revoke that Activity ownership.
The existing single-resume fallback remains for older engine-only builds;
the dual-engine product requires API 29.

A posted attach/resume recheck observes current lifecycle state. Pause or loss
of top-resumed ownership retires an already claimed non-PiP lease before a late
callback can reclaim it. Existing explicit PiP policy remains intact. The
change does not synthesize connection, rendered-frame or audio observations.

## Named verification

`MoonlightForegroundWindowTest` uses the actual packaged merge layout and the
actual upstream SpinnerDialog at the post-create window boundary. It does not
run unavailable JVM network/MediaCodec setup. Against the old production
wrapper, its first three tests produced two passes and one intended failure:
the resumed top Activity with its owned spinner remained `TRANSFER_PENDING`.

After the repair, four tests pass: owned modal focus, non-top/paused ownership,
hidden/finishing ownership, and unattached ownership. The claimed lease still
has zero rendered-frame and accepted-audio witnesses. The existing 44-case
`MoonlightEmbeddedRuntimeTest` also passes, with zero failures/errors/skips.
`compileDebugAndroidTestKotlin` passes. The current product manifest cannot
execute the additional exploratory API 28 Robolectric case because its minimum
SDK is 29; that exploration is not counted as passed verification.

Private root evidence: `/private/tmp/larenor-f60-top-resumed-root-20261001`,
`red-final.log` and `green-final-supported.log`, directory 0700, logs 0600.
A separate read-only agent reviewed lifecycle, late callback and PiP fencing.

## Acceptance limits

Exact d81febad CI run 36830633169 failed at `firstStreamOutput` with the closed
`leaseUncertain`/`unknown_effect` diagnostic. This local reproduced defect is
compatible with that failure, but does not establish its sole remote cause.
The strict owned Sunshine/Android gate must still prove actual frame/audio,
input, two lifetimes and terminal disconnect on changed source. F60 remains
reworking until that gate is green; this evidence does not advance acceptance.
