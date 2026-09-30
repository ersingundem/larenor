# F60 packaged Android CI boundary — 2026-10-01

`.github/workflows/moonlight-android-native.yml` builds the exact reviewed
Moonlight Android 12.2 recursive source with the embedded-library patch. The
source verifier checks the upstream commit/tree, submodules, licenses, reviewed
source blobs, bundled archives and patch hash before building. The receipt
verifies the actual AAR classes and both `arm64-v8a` and `x86_64` native libraries.

The same job installs that receipted AAR into Larenor, compiles a real two-ABI
debug APK, and verifies its DEX/native contents. It runs the original embedded
runtime, production MethodChannel bridge and legacy adapter regression classes.
Each named XML suite must exist, contain tests, and have zero failures, errors
and skips. A bounded public lifecycle receipt records those aggregate counts,
the exact checkout revision and the package receipt digest. Raw reports and
provider diagnostics are not published by this job.

Only the same repository's `main` pull-request merge ref or an explicit dispatch
from `main`/`codex/project-completion-100` on a GitHub-hosted runner is accepted.
The workflow source must match `GITHUB_SHA`; checkout credentials are not
persisted and every action is commit-pinned. The package artifact includes the
AAR, canonical receipt and corresponding pinned recursive source with the
reviewed patch/notice, retained for 14 days.

Local workflow verification: `actionlint`, JSON parsing, `bash -n` for every run
step, and parsing the embedded Python gate passed. The workflow has **not yet
executed on GitHub**. These local checks do not establish hosted packaging or
real Sunshine pairing, streaming, input, stop or revocation acceptance.

The package/lifecycle job uses no household host or credentials. Real owned
Sunshine-to-packaged-Android protocol acceptance is a separate, still-open
software gate. Physical Huawei/DeX, GPU/codec performance, latency and
controller behavior remain the named manual gates. F60 is not accepted from a
package receipt or a mocked lifecycle test.
