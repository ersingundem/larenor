# F62 registered Gateway Android workflow

This slice registers two explicit manual scopes in `.github/workflows/server-test.yml`:
`f62-gateway-android-direct` and `f62-gateway-android-public`. Both call one
reusable workflow with a literal `direct` or `public` input. The reusable
workflow has no independent `workflow_dispatch` trigger.

The first workflow step maps the input through a closed two-value case. It
selects fixed test classes, test methods, private receipt names, and public
artifact names. Unknown, mixed-case, path-like, and shell-like values fail
before checkout or network access. The raw workflow input is never inserted
into a command.

Both scenarios rebuild the exact source-locked Moonlight package and both
FreeRDP ABIs, install them as one product, build the application and
AndroidTest APKs, and verify the combined APK. DIRECT runs
`RdpPackagedGatewaySafAcceptanceTest.gatewaySafProvesTwoHopPinsNlaAndRdpdrRoundTripAfterExplicitDrain`.
PUBLIC runs
`RdpPackagedGatewaySafPublicBridgeAcceptanceTest.gatewaySafPublicMethodChannelPathProvesTwoPinsNlaRdpdrDrainAndSafReadback`.
The PUBLIC path uses the product MethodChannel and capability admission. The
workflow sets no admission override and does not make either scenario an
accepted feature.

The AndroidTest APK is read from
`build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk`. This
matches `android/build.gradle.kts`, which redirects the root build directory
to `../../build` and each subproject to `build/<project>`. The former
`android/app/build/...` path is rejected by the policy regression.

`f62_gateway_android_hosted.py prepare` records the checked-out Git revision
and tree with the trusted Git executable. The fixture writes a private raw
effect receipt. The workflow validates that receipt, joins it to the launcher,
Android build, APK, product, source, target, and named-test identities, then
validates the joined schema-3 receipt. Only that joined receipt is copied to
`test-results`, and only the fixed scenario-specific upload step can publish
it. Join or validation failure cannot produce a success artifact.

The always-run cleanup removes credentials, descriptors, logs, emulator
inputs, fixture processes, temporary native packages, and the private raw
receipt before artifact upload. Closed Android-build and target-build failure
receipts remain independently uploadable on failure. Raw instrumentation logs,
provider configuration, credentials, and effect receipts remain private.

Local policy evidence:

- the focused workflow test executes the extracted scenario-binding shell for
  both valid values and rejects four invalid values;
- the same test requires literal server dispatch registration, exact
  class/method selection, fresh dual-ABI product construction, joined-receipt
  ordering, cleanup-before-upload, fixed artifact labels, and no admission
  bypass;
- `actionlint` validates both workflows.

These checks establish workflow structure only. No GitHub-hosted Android
scenario was dispatched by this slice. PUBLIC remains blocked from acceptance
until a genuine DIRECT receipt is accepted and a later PUBLIC hosted run
passes through the real admission path.
