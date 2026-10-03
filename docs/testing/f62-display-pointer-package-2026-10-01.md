# F62 FreeRDP display and relative-pointer package prerequisite

Date: 2026-10-01

## Scope

This slice prepares and builds a source-locked FreeRDP Android package contract
for the F62 display and pointer implementation. It does not mount the package
in the app, exercise an RDP server, or establish runtime input or display
acceptance.

The package identity is
`freerdp-3.31.1-63b948ca-clipboard-utf8-display-pointer-v2` with JNI schema 2.
The new reviewed patch has SHA-256
`749ccab1c74a47adec311f67b7464de94703026d6ddb7530e62e1656d8f9b3d4`.
The immutable FreeRDP 3.31.1 archive remains bound to commit
`63b948ca5cb94307fd5444ee6e73927a41ccdab4` and archive SHA-256
`4a2629026896cb4e26fb8ed2d6ca6aa4ab89ca95528dfbae2550c2f6bc866991`.

## Reviewed contract

- `sendRelativeCursorEvent(long,int,int,int):boolean` accepts bounded signed
  16-bit deltas and a bounded relative move/button flag set, then enqueues the
  event on the existing Android FreeRDP connection-thread queue. The JNI entry
  does not call the wire sender directly.
- The connection-thread handler calls
  `freerdp_input_send_rel_mouse_event`. The pinned implementation itself
  rejects transmission unless `FreeRDP_HasRelativeMouseEvent` was negotiated.
- `isRelativeMouseInputSupported(long):boolean` reads that same negotiated
  setting. It is a connected-session observation; callers must keep the value
  false before `OnConnectionSuccess` and must not treat the upstream default as
  negotiation evidence.
- `freerdp_client_use_relative_mouse_events` also includes the
  `MouseUseRelativeMove` UI preference and an optional AINPUT fallback. That
  function is not used as the protocol capability because this API sends the
  RDP relative-pointer PDU directly.
- `sendMonitorLayout(long,int,int,int,int):boolean` requires an even width in
  200..8192, height in 200..8192, desktop scale in 100..500, and device scale in
  `{100,140,180}`. The explicit values are copied to the single-primary DISP
  layout; stale settings-derived scale values are rejected by the source
  verifier.
- `OnDisplayControlReady(long)` is emitted only after the exact connection
  receives and validates the peer's `DISPLAY_CONTROL_CAPS_PDU`. Merely
  installing the DISP context does not emit it. The EventListener descriptor
  and native callback invocation are package-bound so a stale schema-1 listener
  cannot be mistaken for this package.
- The exact peer monitor count and area factors are stored per connection,
  cleared at DISP init and uninit, and checked before every monitor-layout send.
  A pre-CAPS send, zero constraint, odd width, out-of-range scale, or requested
  area above the overflow-safe peer limit is rejected. A true return proves
  that the layout was submitted to the negotiated DISP channel; host
  application and framebuffer change still require provider readback.
- The AAR receipt is bound to JNI schema 2, the exact three public Java method
  descriptors, the JNI entry points, and the queued relative sender evidence.
  A schema-1 receipt or an old Java surface is rejected.

Primary pinned sources:

- [FreeRDP Android Java API](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/client/Android/Studio/freeRDPCore/src/main/java/com/freerdp/freerdpcore/services/LibFreeRDP.java)
- [FreeRDP input API](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/include/freerdp/input.h)
- [FreeRDP relative-pointer sender](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/libfreerdp/core/input.c)
- [FreeRDP client relative-pointer policy](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/client/common/client.c)
- [FreeRDP Android DISP client](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/client/Android/Studio/freeRDPCore/src/main/cpp/android_disp.c)
- [FreeRDP DISP CAPS dispatch](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/channels/disp/client/disp_main.c#L168-L180)
- [FreeRDP X11 CAPS readiness precedent](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/client/X11/xf_disp.c#L518-L564)
- [MS-RDPEDISP CAPS PDU](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpedisp/8989a211-984e-4ecc-80f3-60694fc4b476)
- [MS-RDPEDISP monitor-layout processing](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpedisp/991bcf69-0248-4b01-9f3b-acfa151d4768)
- [MS-RDPEDISP monitor-layout PDU](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpedisp/22741217-12a0-4fb8-b5a0-df43905aaf06)

## Evidence

The initial package test failed during collection because the v2 API contract
did not exist. After the implementation and coordinated native identity update:

- `python3 -m unittest tool.tests.freerdp_android_package_test tool.tests.product_android_native_test tool.tests.freerdp_android_workflow_test`:
  29 passed.
- `python3 tool/freerdp_android_package.py verify-lock`: passed.
- `python3 tool/freerdp_android_package.py verify-source <private exact archive>`:
  passed for all 12 reviewed blobs.
- `python3 tool/freerdp_android_package.py verify-patch <private prepared source>`:
  passed after all three reviewed patches.
- `python3 -m py_compile tool/freerdp_android_package.py tool/tests/freerdp_android_package_test.py`:
  passed.
- The first real native compile rejected a split JNI identifier. After the
  verifier-bound contiguous identifier repair, a later arm64 package built
  with an init-time readiness callback; source review invalidated that package
  before mounting because peer DISP CAPS had not yet arrived. It is not package
  evidence for this contract.
- Fresh corrected peer-CAPS builds used Java 17, Android platform/build tools
  37, NDK 29.0.13113456, CMake 4.1.2, one Gradle worker, and the exact reviewed
  three-patch source. Both packages passed `receipt` and `verify-install`:
  - arm64-v8a AAR
    `/private/tmp/larenor-f62-v2-caps-build-20261003.shoKQu/arm64-v8a/freeRDPCore-arm64-v8a.aar`,
    SHA-256 `508fcaa84a6aa6061cc632162176354213db1de9eadfc8eab853124aefd48364`;
    receipt SHA-256
    `72951a985656ad9b7c3fefb79b5c042c1611bca4db796db0edc3cbc512bccddc`.
  - x86_64 AAR
    `/private/tmp/larenor-f62-v2-caps-build-20261003.shoKQu/x86_64/freeRDPCore-x86_64.aar`,
    SHA-256 `6e353aba838485f69a2867159c69e05965e7c1e64b169cf7fe53e17e34b61130`;
    receipt SHA-256
    `f6a2a25f84cc11acde930f29135c0b76406d09412b9df2363f5d85f189913c85`.
- Each AAR contains only its declared ABI, four required FreeRDP/WinPR native
  libraries, and the same exact classes SHA-256
  `c1fb99bb30bfdbe26ad8db6a7475482ae82f179ea83a6c0842ac877ad8f7a246`.
  `javap` independently confirmed relative send/query, legacy and v2 monitor
  layout descriptors, and `OnDisplayControlReady(long)`.

Neither corrected AAR was mounted in the app in this slice. Actual runtime
negotiation, relative-pointer effects, vertical-wheel effects, initial and
resized DISP layouts, and owned-host frame readback remain separate native and
provider acceptance gates.

Root integration on 2026-10-03 independently verified both exact AAR and
receipt hashes, installed and verified the complete dual-ABI product, and
recorded merged AAR SHA-256
`29812970c261502c22217a7c7cb667a3d90ad615f473748a7453b77a629bbed4`.
The shared native/Moonlight gate passed 90/90 tests with zero skips, failures
or errors; AndroidTest Kotlin compilation passed. The earlier unmounted slice
statement is historical. These checks remain distinct from hosted provider
acceptance.
