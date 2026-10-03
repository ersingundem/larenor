# F60 exact-a8 owned-stream failure review — 2026-10-01

## Run and artifact identity

GitHub run [36835162847](https://github.com/ersingundem/larenor/actions/runs/36835162847)
completed with `failure` at exact revision
`a8dda8956d251a65021b8aa28a0472fb8a12c0ea`. The owned stream job was
`110280720297`. Toolchain, owned-host dependencies, hosted UHID preflight,
source-locked Moonlight build/install, and hosted KVM preparation passed. The
real owned Sunshine stream step failed; bounded failure collection and owned
host cleanup then passed.

The run produced exactly one active artifact:

- artifact ID `11149980532`
- name
  `f60-sunshine-android-stream-a8dda8956d251a65021b8aa28a0472fb8a12c0ea-failure-diagnostics`
- archive size 941 bytes
- GitHub and independently computed archive SHA-256
  `f6b4742d906af5e64c968754b2c0e4e2ed277ebb3e6cc275311d2415106b7f87`
- canonical JSON size 1397 bytes
- canonical JSON SHA-256
  `125bf2647523cb689612086c47a7830387b344b71b9188e7b06af75989169d8c`

The artifact was downloaded to a private 0700 directory with 0600 files. Its
JSON is byte-for-byte equal to the canonical
`json.dumps(separators=(",", ":"), sort_keys=True)` representation plus one
newline. The current production runner is byte-identical to the exact-a8
runner, and its production failure-diagnostic validator accepted the payload.
The outer receipt also has the exact closed schema, exact source revision,
source-locked embed-v3 package identity, and fixed failed result.

## Closed diagnostic facts

The original named test executed once: one failure, zero errors, zero skips.
It failed at `firstStreamOutput` with an owned frame at
`MoonlightOwnedSunshineStreamTest.kt:223`; the second owned frame is the fixed
diagnostic assertion. The PIN bridge reached `pairedClientObserved`.

The command and process-private dispatch facts are:

- command state/result/observation: `unknown` / `unknown` / `unknown`
- exact lease claim: `gameVisible`
- dispatch terminal stage: `timeout`
- bounded runtime failure: `unknown_effect`
- command classification: `leaseGameVisible`

These facts establish that the exact Game Activity launched, attached, became
the owned foreground activity, and remained represented by the exact lease.
They also establish that the stream command did not receive its required
`connectionStarted` observation within the existing 30-second bound. They do
not establish a rendered frame, accepted PCM write, input effect, second
lifetime, stop, disconnect, or local retirement.

## Source review and comparison

The exact-a8 `LarenorMoonlightGame.connectionStarted()` forwards the callback
to `MoonlightForegroundLeaseRegistry.connectionStarted()`, which is the only
path that emits the command's `connectionStarted/streaming` observation. The
runtime timeout publishes `unknown_effect` when that callback does not win.

Pinned Moonlight Android 12.2 starts its `NvConnection` only from
`Game.surfaceChanged()`. The connection worker must then complete its HTTP app
stage and `MoonBridge.startConnection()` before the upstream listener can
invoke `Game.connectionStarted()`. Therefore the closed receipt is compatible
with several distinct boundaries: no usable surface callback, an HTTP start
failure or stall, a native connection-start failure or stall, or a callback
that never reached the exact Game. The retained public receipt does not expose
which boundary occurred, and no one of these is claimed as the root cause.

Primary pinned sources:

- [Moonlight Game.java at b48494cb](https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/Game.java)
- [Moonlight NvConnection.java at b48494cb](https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/nvstream/NvConnection.java)

The historical exact-d81 result had the same high-level `unknown_effect` but
reported `leaseUncertain`. Between d81 and a8, the owned spinner/foreground
repair removed focus as a prerequisite for claiming the visible Game. The a8
receipt's `gameVisible` fact is consistent with that repair working and narrows
the remaining failure to the interval after Activity claim and before the
required connection callback. It does not retrospectively prove the sole cause
of d81.

The smallest safe next diagnostic is an exact-token, process-private finite
state trace for `surfaceCreated`, `surfaceChanged`, connection stage start,
connection stage complete/failure, native start return, and
`connectionStarted`. A public failure receipt may expose only one closed enum
from that trace. It must not publish upstream messages, endpoints, host or
client identifiers, certificates, PINs, codec payloads, pixels, PCM, or raw
logs, and it must preserve the original named one-test/no-skip acceptance gate
and current timeout.

This run is not F60 acceptance. It supplies no success receipt and F60 remains
reworking.
