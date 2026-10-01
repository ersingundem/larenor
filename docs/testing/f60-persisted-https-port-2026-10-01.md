# F60 persisted Moonlight HTTPS port repair — 2026-10-01

The pinned Moonlight `ComputerDatabaseManager` persists UUID, name, address
tuples, MAC address and server certificate. `ComputerDetails.httpsPort` is a
transient field, so a database read returns zero even when the paired
in-memory record originally observed port 47984. Pinned `Game` documents zero
as the unknown HTTPS-port sentinel, and `NvHTTP` resolves the port from HTTP
`serverinfo` before its first HTTPS request. That subsequent HTTPS connection
still validates the stored server-certificate pin.

Larenor's private launch specification previously required the HTTPS port to
be positive. The production stream path reloads the paired computer from the
upstream database, so this rejected the valid zero sentinel with
`IllegalArgumentException` before a foreground lease could be issued. The
strict hosted F60 run `36825268673` observed this exact boundary as
`beforeIssue`, with no readable lease.

The launch contract now accepts only `0..65535` for HTTPS while retaining a
strictly positive HTTP port. Zero remains private native metadata: no endpoint
or port crosses the Flutter/Core boundary. A focused regression writes a
computer with an observed HTTPS port through the actual upstream database,
reads back the transient zero, and proves that exact value is accepted for a
Game launch. Negative and out-of-range ports remain rejected.

This is a source-level composition repair. It does not establish a successful
Sunshine stream, rendered frame, PCM output, input effect, disconnect or
physical playback; the strict owned-host gate remains required.

## Verification

The regression uses the actual pinned upstream SQLite database. With the old
positive-only guard, the new persisted-computer case failed with
`IllegalArgumentException`. With the corrected sentinel contract, the focused
`MoonlightEmbeddedRuntimeTest` suite passed **43 tests, 0 failures, 0 errors,
0 skips**. Root independently checked the preserved JUnit XML and task log.

Canonical v3 AAR/receipt verification passed. The required-native
`:app:compileDebugAndroidTestKotlin` invocation completed successfully
(314 tasks, 9 executed; AndroidTest compile was up-to-date). Compilation does
not establish device execution. A changed-source strict owned Sunshine run
must still prove rendered frames, audio and input.

## Pinned primary sources

- [ComputerDatabaseManager](https://raw.githubusercontent.com/moonlight-stream/moonlight-android/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/computers/ComputerDatabaseManager.java): persisted fields omit the transient HTTPS port.
- [Game](https://raw.githubusercontent.com/moonlight-stream/moonlight-android/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/Game.java): the HTTPS-port launch extra uses zero for unknown.
- [NvHTTP](https://raw.githubusercontent.com/moonlight-stream/moonlight-android/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/nvstream/http/NvHTTP.java): serverinfo resolves unknown ports and the TLS trust manager enforces the existing certificate pin.
