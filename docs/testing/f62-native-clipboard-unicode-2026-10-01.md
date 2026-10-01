# F62 native clipboard Unicode contract — 2026-10-01

## Defect and production boundary

FreeRDP 3.31.1 commit
[`63b948ca5cb94307fd5444ee6e73927a41ccdab4`](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/client/Android/Studio/freeRDPCore/src/main/cpp/android_freerdp.c#L1133-L1149)
uses `GetStringUTFChars` and `GetStringUTFLength` in the Android text clipboard
JNI method. Android documents that these APIs produce modified UTF-8, while a
Java `String` is UTF-16 and arbitrary UTF-8 must not be assumed to have the same
encoding ([Android JNI string guidance](https://developer.android.com/ndk/guides/jni-tips#utf-8-and-utf-16-strings)).
The FreeRDP clipboard synthesizer consumes `text/plain` as standard UTF-8, so a
supplementary Unicode character could be corrupted before it reached the RDP
clipboard conversion path.

`android/freerdp-clipboard-utf8.patch` keeps the existing JNI method identity
and fixes that boundary:

1. It reads the Java string as UTF-16 with `GetStringChars` and its explicit
   length.
2. It rejects empty input, embedded NUL, unpaired high or low surrogates, more
   than 64 Ki UTF-16 code units, and a standard UTF-8 result larger than 64 KiB.
3. It converts the validated UTF-16 units with FreeRDP/WinPR's pinned
   [`ConvertWCharNToUtf8Alloc`](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/winpr/libwinpr/crt/unicode.c#L549-L570)
   before creating the existing `text/plain` event.
4. It releases the JNI characters and securely clears and frees both temporary
   native buffers. The queued event's owned text buffer is also cleared before
   it is freed.
5. It removes the raw clipboard text log. The remaining debug event reports
   only whether enqueueing succeeded.

The patch does not enable clipboard redirection by default. The production
capability remains explicit `clientToRemote`; server-to-client clipboard remains
unsupported.

## Immutable package evidence

`android/freerdp-native.lock.json` retains the original FreeRDP source archive,
commit, reviewed blobs, certificate patch, ABIs, and toolchain. It adds the
reviewed `android_event.c` blob and binds this exact ordered patch chain:

1. `android/freerdp-certificate-pem.patch`
2. `android/freerdp-clipboard-utf8.patch`

The package identity is
`freerdp-3.31.1-63b948ca-clipboard-utf8-v1`. A package receipt includes both
patch paths and hashes. The AAR is rejected unless `libfreerdp-android.so`
contains the real unresolved/linked native evidence name
`ConvertWCharNToUtf8Alloc`. The old Android JNI source does not call that
helper, so an old unpatched AAR cannot satisfy the revised receipt contract by
retaining only `JNI_OnLoad`.

The packaging tool also verifies the applied source shape: exact UTF-16 access,
surrogate/NUL/size checks, standard UTF-8 conversion, cleanup order, event data
clearing, and absence of the old modified UTF-8 calls and raw text log. This is
source and package evidence; it is not a substitute for a remote clipboard
effect observation.

## Focused evidence

The red test run failed while `verify_clipboard_patch` was absent. After the
implementation:

```text
python3 -m py_compile tool/freerdp_android_package.py \
  tool/tests/freerdp_android_package_test.py
python3 tool/freerdp_android_package.py verify-lock
python3 -m unittest tool.tests.freerdp_android_package_test

Ran 9 tests in 0.035s
OK
```

The focused suite covers the unchanged pinned source rejection, exact ordered
patch hashes, tampered/reordered patch lock rejection, semantic applied-source
validation, and rejection of an AAR that lacks the compiled UTF-8 helper
evidence. The two patches also applied in lock order to the exact pinned source
archive, and `verify-patch` accepted the resulting source tree.

## Remaining named evidence

The initial focused patch slice did not build a native AAR or run Android
instrumentation. The independent native rebuild below now establishes the
new x86_64 package and application compilation. The hosted package workflow
must still build both ABIs and the exact Linux fixture, then send a supplementary
character through the production Android client and observe the exact UTF-16
clipboard value on the owned RDP server. Until that gate passes, remote emoji
interoperability remains unverified.

## Independent rebuilt native package

Root rebuilt the exact release asset with the two locked patches, Java17,
NDK29.0.13113456 and actual CMake4.1.2 for x86_64. The real upstream
`:freeRDPCore:assembleRelease` succeeded; the new package receipt and
`verify-install` passed with all four native libraries.

- AAR SHA256: `03ea2f3fbee95a6ca7bd92703ac8c2d529a6a36e3edbfc890cbc6ea256cdfb2f`
- Receipt SHA256: `ac4804d32f77a50950f774bff1f5442805fe9bc00104b0041713595f5eec14f1`
- Engine: `freerdp-3.31.1-63b948ca-clipboard-utf8-v1`

Both retained old x86_64 AARs lacked the new native conversion helper and are
rejected by the new identity/evidence contract. The JNI allocation sizes were
independently checked against pinned WinPR: WCHAR is16-bit, and the standard
UTF8 converter allocates returned byte length plus one terminal NUL, matching
the secure erase bounds. This proves real native compilation and package
identity. It does not prove remote emoji readback, Linux shadow compilation,
or the two real Android/NLA lifetimes; those remain hosted gates.

## Application and Android test compilation

Root temporarily installed only this verified AAR and receipt in the initially
absent local package directory. With Java17 and the configured Android SDK,
the real Gradle invocation completed successfully:

```text
:app:compileDebugKotlin
:app:compileDebugAndroidTestKotlin
:app:testDebugUnitTest --tests '*Rdp*'
BUILD SUCCESSFUL in 27s
```

The actual RDP unit XML reports contain **24 tests, zero failures, zero errors,
and zero skips**. The exact temporary package files were removed after the
invocation. Root also passed **105 Python checks** covering the package,
owned channel fixture, real acceptance runner, workflow and queue/progress
gates; workflow actionlint and `git diff --check` passed. These results prove
compilation and local contracts, not remote channel effects or Android
instrumentation execution.
