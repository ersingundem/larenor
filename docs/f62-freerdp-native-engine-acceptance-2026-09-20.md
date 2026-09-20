# F62 FreeRDP Android native engine gate

20 September 2026. This bounded slice keeps F62 pending and the queue at
**17/125 · 0/63**. It supplies the reviewable package and JNI contracts below;
it does not claim a successful Windows, RD Gateway, Huawei tablet or Samsung
DeX session.

## Three software acceptance criteria

1. **Immutable package identity and security gate.**
   `android/freerdp-native.lock.json` pins FreeRDP 3.31.1 to release commit
   `63b948ca5cb94307fd5444ee6e73927a41ccdab4`, the official release archive
   SHA-256, four reviewed upstream JNI/build file blob IDs, Android build
   tools, NDK 29.0.13113456, CMake 4.1.2 and the arm64-v8a/x86_64 ABI set.
   The GitHub-hosted package workflow verifies the archive before extraction,
   builds each ABI without emulation, checks the ELF architecture and required
   FreeRDP/WinPR libraries, and emits a digest receipt. Runtime identity must
   match that same tuple and report no default channel before an operation can
   be created. TLS 1.2/1.3, exact SPKI pin evidence and requested NLA gate the
   active state; mismatch closes once with a redacted, non-retryable code.
2. **Bounded framebuffer and tablet/DeX interaction.**
   The native boundary accepts only writable direct BGRA buffers with exact
   stride, bounded dimensions/DPI/pixel count and at most 64 MiB. One frame is
   outstanding until its exact sequence is acknowledged; a duplicate, replay
   or second frame fails closed and wipes the buffer. Pointer, physical key,
   bounded UTF-8 IME text and dynamic resolution/external-display changes use
   a single monotonic input sequence. The native operation must synchronously
   accept or reject each item, which provides the bounded queue/backpressure
   seam without retaining Dart/Kotlin secrets.
3. **Explicit channels and terminal ownership.**
   Clipboard, audio and file requests are separate closed fields and start
   disabled. Negotiation rejects an unsupported request, while a live session
   accepts channel data only when both the engine capability and that exact
   session request allow it. Payloads are bounded and cleared after the native
   call. Disconnect, close, security replay, sequence gaps and native linkage
   failures detach and close the operation once; late callbacks cannot reopen
   it and there is no automatic retry or reconnect path.

## Local evidence

- Android JVM: **12/12** tests in `RdpNativeContractTest`,
  `RdpFreeRdpPackageTest` and
  `RdpFreeRdpEngineTest` cover the closed schemas, package mismatch, TLS/NLA/
  pin rejection, direct frames, one-frame backpressure, pointer/key/IME,
  DeX-style resize, channel denial, disconnect and replay.
- Python policy: **7/7** tests in `freerdp_android_package_test` and
  `freerdp_android_workflow_test` cover archive/path/blob tamper, mixed/wrong
  ABI rejection, exact receipts, pinned actions, same-repository execution,
  minimal permissions and absence of production addresses or secrets.
- The normal product build remains fail closed. A workflow artifact is build
  evidence, not an automatically trusted application dependency.
- Existing Flutter RDP model/controller/security/panel regression is **21/21**
  and targeted analysis reports no issue.

## Acceptance deliberately still open

F62 cannot be marked done until a reviewed concrete `RdpJniRuntime` binds the
receipted AAR into the Android product, Client frame rendering and lifecycle
permission prompts use that runtime, and an isolated owned Windows fixture
proves a real TLS/NLA handshake, pinned identity, decoded framebuffer, input,
disconnect and loss behavior. Real RD Gateway and advanced channel support
need their own motor/host matrix. Huawei MatePad, Samsung DeX, external display,
Turkish dead-key/IME, pointer, audio/clipboard permission and long-session
checks remain in manual physical acceptance. File, drive, microphone, printer,
USB, smart-card, RemoteApp, H.264/GFX and UDP remain unavailable.
