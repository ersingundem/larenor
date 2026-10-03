# F60 owned touch-effect fixture correction

The exact hosted run at source revision
`7e55247f2b1badede5ef1641cda53aec1a4782c1` reached the first owned stream,
rendered frames, accepted nonzero PCM, started the XI2 listener, and entered
`touchEffect`. Its original named Android test then failed while the bounded
phase observation was still `active/error:none`. The retained receipt does
not identify the missing XI2 subfact, so it does not prove a provider or
production-input failure.

Source review found a deterministic acceptance-fixture mismatch. The fixture
constructed `SOURCE_MOUSE_RELATIVE` events with deltas in
`AXIS_RELATIVE_X/Y`. Pinned Moonlight Android commit
`b48494cb96bff23d8886c4775cc4f39a1075495d` reads `AXIS_X/Y` for that
source in `AndroidNativePointerCaptureProvider`. `Game` consequently sees
zero deltas and does not call `sendMouseMove`. The fixture also sent one
explicit mouse-move event, while the real XI2 witness requires two distinct
positions and a primary-button press/release.

The corrected fixture writes two bounded nonzero deltas through
`PointerCoords.x/y`, exactly matching the pinned provider path, before the
existing primary-button pair. It retains the touchscreen sequence and invokes
the real packaged `Game.dispatchGenericMotionEvent`; it does not inject a
Moonlight packet or synthesize a host receipt.

The Android control read is bounded at 90 seconds. Previously the host waited
up to 300 seconds for XI2, so Android could fail first and leave only an active
phase observation. The XI2 effect wait is now capped at 60 seconds. A missing
effect therefore becomes the existing closed
`touchEffect/failed/xi2EffectTimeout` observation before the Android peer
retires. Listener readiness, real X11 motion/button evidence, foreground
ownership, gamepad, audio, frames, two stream lifetimes, disconnect, and local
retirement remain mandatory.

Focused regressions bind the exact fixture source hash, require the two
Moonlight-compatible move events, reject the old relative-axis encoding, and
exercise the phase bridge with an immediate simulated XI2 timeout to prove the
60-second argument and closed diagnostic. These are software tests. A
changed-source hosted run remains required to prove the real XI2 effect and
must not be inferred from this correction.

Root independently reviewed the frozen relative-axis and timeout patch and checked every base/candidate hash. Combined stream/workflow gate **85/85 passed**, log SHA-256 `6149ee90b409ba313275cd2a781f2d3679cdfb220ffaa551096636f53dbebb0d`. Actual composed native5/Moonlight5 AndroidTest compile passed **276 tasks:17 executed,259 up-to-date**, log SHA-256 `ebeda299257d1eb7d7b65e7f4184698773e5e6987e10bafaee6d40767c6e03c7`. This compiles the owned test against real embedded engines; it does not establish actual XI2/stream effects or acceptance.
