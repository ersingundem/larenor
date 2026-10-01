# Product FreeRDP ABI isolation — 2026-10-01

Android Build run `36813872693`, at source
`36269cf05091156ae960106eaec27810ff35fc78`, failed the two-ABI FreeRDP
package step with `mixed_abi_aar`. FreeRDP's Android external dependency build
installs native libraries inside the source tree, under the ABI-specific
`Studio/freeRDPCore/src/main/jniLibs` directory. Reusing that source tree for
arm64 and x86 left arm64 libraries in the subsequent x86 AAR. Removing only
the `.cxx` build directories did not remove those source-tree outputs.

This path was also checked against the
[official pinned FreeRDP source](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/client/Android/cmake/ExternalDeps.cmake):
the dependency install prefix is inside the source tree and includes the ABI.
That external source confirms the packaging mechanism; the failed hosted
receipt and actual isolated builds establish this repository's repair.

The workflow now extracts the same verified, pinned archive into a separate
source tree for each ABI. Both trees receive the same reviewed patches and
package verification. The existing strict single-ABI and merged-product
receipt checks remain required.

## Actual local evidence

| Input | AAR SHA-256 | JNI libraries |
| --- | --- | --- |
| arm64-v8a | `5c33029bf7420d4ac4fa5c80260a79fa54c057bf0bcf177c0264e03c07225653` | 9, all arm64-v8a |
| x86_64 | `1e065bcf91ad30f57fa669e316f783998b0f6f97239bf5af268ff44d9d646729` | 9, all x86_64 |

Both real builds have the same `classes.jar` SHA-256:
`a744d652ca862fa9d5035f55858f78f5b26f1c9268abb888a97195bf0ad815be`.
Root independently inspected both archives and passed the production
`product_android_native.py verify-installed` check against their actual
combined product. The workflow/package suite passed 5 tests; actionlint and
Git whitespace checks passed.

The private build evidence is in
`/private/tmp/larenor-product-freerdp-isolated-proof-20261001-b`.
Its AAR inputs, merged product, receipts and logs are retained. The disposable
source trees and Gradle cache were removed after the local test host ran out
of disk space. These files are reproducible from the pinned archive and
patches. Local package verification does not establish hosted Android build,
real RDP interoperability or final-HEAD acceptance.
