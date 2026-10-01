# Product Android dual-native composition evidence

Date: 2026-10-01

## Delivery boundary

The ordinary Android build used to omit both optional engine packages. The
feature-specific native workflows proved an engine in isolation, but neither
the debug product APK nor the signed beta APK materialized those packages.

The product build now has a separate source-locked input job. It builds and
receipts:

- Moonlight Android 12.2 at the commit, recursive submodules, patch and two-ABI
  contract in `android/moonlight/source-lock.json`;
- FreeRDP 3.31.1 at the archive digest, JNI patches and toolchain in
  `android/freerdp-native.lock.json`, once for `arm64-v8a` and once for
  `x86_64`.

The job retains the exact upstream source bundles, repository patches, locks
and NOTICE material beside the AAR receipts. The source bundles are build
provenance; the public repository locks, patches and NOTICE files remain the
long-lived corresponding-source pointers.

`tool/product_android_native.py install` validates all three source
AAR/receipt pairs before writing product inputs. It requires the two FreeRDP
variants to have byte-identical non-native AAR content, then combines only the
verified ABI-specific JNI entries. A content-bound product receipt is written
last. It includes every merged FreeRDP native library, including transitive
libraries not individually listed by the upstream package receipt.

Both debug and signed-release jobs download the input artifact from the same
workflow and source revision, install it, set
`LARENOR_PRODUCT_NATIVE_ENGINES=required`, and build one APK restricted to the
two supported ABIs. Gradle fails before compilation when that explicit product
mode lacks either engine or either FreeRDP ABI receipt. Builds without the flag
retain the existing honest local-development behavior: either engine may be
absent and its runtime reports unavailable.

After the one APK is built, the product verifier runs Moonlight's APK verifier,
FreeRDP's APK verifier for each ABI receipt, and an exact check for every merged
FreeRDP JNI library. Signed release identity and publication gates remain after
this native-content gate and retain their existing main-only secret boundary.

## Local evidence

- `python3 -m unittest tool.tests.product_android_native_test` — 5 passed.
- `env -u PYTHONPATH python3 tool/product_android_native.py --help` — direct
  entry point succeeded from a clean import environment.
- Android workflow/security policy set — 58 passed across the product helper,
  signing, scope, beta release, required-CI, security, SDK setup and Gradle
  cache tests.
- Existing Moonlight and FreeRDP package helper suites — 16 passed.
- `actionlint .github/workflows/android-build.yml` — passed.
- `git diff --check` on the owned files — passed.

The focused tests exercise verification before installation, byte-identical
FreeRDP variant enforcement, two-ABI merge, product-receipt tamper rejection,
dual-engine APK verification dispatch, direct CLI startup and exact workflow
dependency/product-mode wiring.

## Remaining external evidence

This slice deliberately did not run Gradle or download/build upstream engines
locally. A fresh CI or isolated verifier must still materialize both immutable
sources, build all three AAR inputs, compile one dual-engine APK, and pass both
engine APK verifiers. Engine-specific real Sunshine and FreeRDP host gates
remain separate evidence; composition does not turn their pending provider
receipts into product acceptance.

The APK contains no `armeabi-v7a` engine support. Product builds explicitly
target `arm64-v8a` and `x86_64`, the intersection named by both engine locks.
