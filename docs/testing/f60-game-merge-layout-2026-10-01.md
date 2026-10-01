# F60 packaged Moonlight merge-layout evidence — 2026-10-01

## Failure and repair

The exact hosted failure at source revision
`ed91234d41667c4c546dbbf6d96de61baaed0134` reported the owned frames
`LarenorMoonlightGame.kt:57` and `LarenorMoonlightGame.kt:48`. The first frame
was the wrapper's manual `inflate(layout, parent, false)` call. The pinned
Moonlight `activity_game` resource is packaged in the verified embed-v3 AAR and
has a `<merge>` root. Android rejects a `<merge>` root unless it is attached to
a valid parent during inflation, as enforced by the AOSP
[`LayoutInflater`](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/master/core/java/android/view/LayoutInflater.java)
`TAG_MERGE` branch.

`LarenorMoonlightGame.setContentView(int)` now delegates the resource attachment
to the normal Activity/PhoneWindow path and then applies the existing secure
surface traversal to the attached content hierarchy. The activity still sets
`FLAG_SECURE` before upstream `Game.onCreate`, keeps the opaque launch token and
scoped storage boundary, and preserves every lease, generation, connection,
frame, audio, input, stop, and termination callback.

## Focused proof

The Robolectric regression uses the real packaged `R.layout.activity_game`. It
requires the real `com.limelight.ui.StreamView` to be attached directly to
`android.R.id.content`, which binds the test to the `<merge>` hierarchy rather
than a replacement wrapper. It reads the attached `SurfaceView` state and
requires the API 35 `SurfaceControl.SECURE` bit set by `SurfaceView.setSecure`,
alongside the window `FLAG_SECURE` assertion. No production-only counter or
replacement test layout stands in for either security property.

This gate proves packaged resource inflation and local secure-surface setup. It
does not claim a Sunshine connection, decoded frame, audio output, input
effect, or remote stream termination; those remain in the owned hosted stream
acceptance gate.

With the verified required dual-engine installation and Java 17, the focused
Moonlight JVM gate passed 44 tests with zero failures, errors, or skips:

```text
LARENOR_PRODUCT_NATIVE_ENGINES=required ./gradlew \
  :app:testDebugUnitTest \
  --tests com.ersingundem.larenor.game.moonlight.MoonlightEmbeddedRuntimeTest
```

The AndroidTest source also compiled with the same required-engine mode:

```text
LARENOR_PRODUCT_NATIVE_ENGINES=required ./gradlew \
  :app:compileDebugAndroidTestKotlin \
  -x :app:compileFlutterBuildDebug
```

That compile is a source and packaging check; it is not an emulator or hosted
Sunshine result.


## Independent root regression and source review

Root ran the same real packaged-layout case against the unchanged old
`setContentView(int)` implementation. It failed with **1 test, 1 failure,
0 errors, 0 skips**, and `android.view.InflateException`. The final frozen
production bytes were restored in a `finally` block. Root then reran the whole
Moonlight embedded runtime module: **44 tests, 0 failures, 0 errors, 0 skips**.
The private root proof directory is
`/private/tmp/larenor-f60-merge-layout-root-20261001/` (0700; logs/XML0600).

The primary source checks are the pinned
[Moonlight game layout](https://raw.githubusercontent.com/moonlight-stream/moonlight-android/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/res/layout/activity_game.xml)
and [Android LayoutInflater](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/master/core/java/android/view/LayoutInflater.java).
The former contains the merge root and real StreamView; the latter rejects a
merge root without an attached valid parent. This reproduces the wrapper's
local inflation fault; it does not establish any later stream effect.
