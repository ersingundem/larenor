# Strict native acceptance at 57f92945

Both runs used exact source
`57f929459a22ab6082e400194e31e0162545f672` and completed unsuccessfully.
Neither feature is eligible for CI-waiting or completion status.

## F60

[Run 36819571890](https://github.com/ersingundem/larenor/actions/runs/36819571890)
contains the original named stream test: **1 test, 1 failure, 0 errors,
0 skips**. Its bounded diagnostic records `pairedClientObserved`, followed
by `firstStreamOutput` at owned test source line 223. This is later than
the previous PIN read boundary. The failing assertion expects the stream
command to return `native_observed`; the published diagnostic does not
establish its actual state or the provider's underlying reason. Pairing
progress is not frame/audio/input or full stream acceptance.

The active diagnostic artifact is `11143132368`. Root downloaded it into a
private directory and verified its source and named-test identity. Its JSON
SHA-256 is
`f1d9a316d902ced0b61968efbd3dd2c2393ded5b450d49daa458d58f6de61a65`.
Raw provider logs and credentials are not published.

## F62

[Run 36819574142](https://github.com/ersingundem/larenor/actions/runs/36819574142)
passed the arm64 package job. The x86 packaged-host job's original named
test reports **1 test, 1 failure, 0 errors, 0 skips**. It fails during
`initialFrameWait` with `RdpOwnedInitialFrameTerminalFailure`;
`serverResizeRequested=false`. This narrows the failure to a terminal
session observed before the initial frame completes. The receipt does not
contain the session failure code or a lifecycle marker, so it does not
prove the native cause or a resize failure.

The active diagnostic artifact is `11143432029`. Its source, counts,
exception class, and owned source frames were independently inspected.
Its JSON SHA-256 is
`d38249d6954ae418882125d77994c41e8e1f2c18b459230030430a024351d0aa`.

## Next boundary

Keep the original real frame/audio/input, TLS/NLA/SPKI, frame ACK, resize,
clipboard, two-lifetime, and cleanup acceptance gates. Establish the exact
remaining cause with bounded source-based diagnostics or a concrete
regression before running changed source again. Do not rerun the same
source or replace native evidence with compilation, synthetic frames,
relaxed assertions, or longer waits.

## Changed-source diagnostic gates

The exact `c9fee6d7ed83807af7917c89b26a7315966ce6cb` [F60 run 36822674910](https://github.com/ersingundem/larenor/actions/runs/36822674910) completed unsuccessfully: original **1 test / 1 failure / 0 errors / 0 skips**, `firstStreamOutput`, `unknown/unknown/unknown`, and `leaseAbsentOrUnreadable`. Its canonical diagnostic artifact `11144616141` has JSON SHA-256 `f97ad4b061ef3b2142a3d8d22d0f0fc5ce269a3d8be59f3c45a39fd933f3e87a`. This does not distinguish a failure before lease issuance from a later launch/callback or readback failure. Root59 runner/workflow checks and actual AndroidTest compilation278 tasks were software evidence, not stream acceptance.

The exact `5aa76fe85e522b2648b5957ebab5f47270af608d` [F62 run 36822994907](https://github.com/ersingundem/larenor/actions/runs/36822994907) completed unsuccessfully. The arm64 package passed; x86 reports the original named **1 test / 1 failure / 0 errors / 0 skips**, `unclassified`, no owned frames or lifecycle/initial-terminal marker, and `serverResizeRequested=false`. Root independently verified canonical artifact `11145056729`, 971 bytes, JSON SHA-256 `cd3018590759cde68f64a2af2c30faa55f27927e148431dd133fbd386f02ae50`, with the production failure-receipt validator. It does not establish the previous initial-frame cause, an app crash, or any particular native defect. Root44 runner/workflow checks and actual AndroidTest compilation277 tasks remain separate software evidence.

The changed exact `691b54c4bf9a5ec7158b22d6142cc17644ccccb9` [F60 run 36825268673](https://github.com/ersingundem/larenor/actions/runs/36825268673) adds a closed, exact-command dispatch-stage and failure-code trace. Root verified actual JVM XML42/0failure/0error/0skip, actual AndroidTest compile277 tasks and60 runner/workflow tests. The run completed unsuccessfully. Its canonical original **1test/1failure/0error/0skip** diagnostic records `firstStreamOutput`, command `unknown/unknown/unknown`, `leaseAbsentOrUnreadable`, and the exact source-locked dispatch tuple **beforeIssue / java.lang.IllegalArgumentException / none**. This narrows the failure to pre-issue code; it does not prove which argument guard failed. Root independently verified active artifact **11145646517**, **1377 bytes**, SHA-256 `0a32214b1c777a8a3eafa58f7001e08c3380a3eea842e933c0ef9ae46dbb72ff`, with the production diagnostic and full canonical receipt validators. No accepted runtime receipt exists. [Trace and trust boundary](f60-stream-dispatch-stage-diagnostics-2026-10-01.md).

These changed-source gates preserve every original acceptance requirement. Neither compilation nor diagnostic-field coverage repairs or proves the old native failure by itself.

## Bounded queue history

The queue evidence array is limited to32 entries. Two unaccepted same-source
APK-prebuild failures, [discovery36799033298](https://github.com/ersingundem/larenor/actions/runs/36799033298)
and [stream36799039362](https://github.com/ersingundem/larenor/actions/runs/36799039362),
are retained here and in the historical progress record rather than taking
two array slots needed for the new exact691 validation/run. Both failed before
instrumentation at the Flutter JNI producer boundary; neither proved a stream
or a provider defect. No accepted runtime evidence was removed.

## Persisted HTTPS-port composition repair

Root source review and the actual pinned upstream SQLite round-trip proved
that the paired record reload produces transient HTTPS port0. The private
positive-only launch guard rejected this before lease issuance. Changed-source
`092a9727` accepts the upstream zero sentinel while keeping all other bounds
and certificate/authority fences. Old guard RED; fixed native suite43/0skip
and required AndroidTestcompile314 passed.

The changed-source strict [run36828275540](https://github.com/ersingundem/larenor/actions/runs/36828275540)
uses exact `ed91234d41667c4c546dbbf6d96de61baaed0134`. No accepted
frame/audio/input receipt exists yet. [Source and primary-source proof](f60-persisted-https-port-2026-10-01.md).

## Archived early preparation records

These failed pre-runtime records were moved out of the bounded32-entry F60
evidence array. Their exact identity and limits remain historical here. They
are not accepted runtime proof and were superseded by later named host/NSD
and strict stream runs.

- [36791191000](https://github.com/ersingundem/larenor/actions/runs/36791191000) — exact `47909b66b1d1bda844f97783e4ac851931a76739`, completed/failed: Owned Sunshine host setup passed, no readiness receipt, exact child cleanup succeeded
- [36792376426](https://github.com/ersingundem/larenor/actions/runs/36792376426) — exact `04552c724fd8a5f981a3f9f64986605f218604a1`, completed/failed: Receipted Moonlight build passed; Android emulator boot timed out before Python, NSD or provider acceptance
- [36796250482](https://github.com/ersingundem/larenor/actions/runs/36796250482) — exact `0036260b9d6eb09336b881889e885328f63d6520`, completed/failed: Engine and explicit KVM passed; ModuleNotFoundError for tool before provider workspace, NSD or instrumentation; no receipt; same-source companion 36796253857 also failed at this preparation boundary
