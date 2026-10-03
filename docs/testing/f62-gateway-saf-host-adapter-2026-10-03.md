# F62 owned Gateway and SAF host adapter (2026-10-03)

## Scope

This private candidate makes the frozen direct Android Gateway and SAF instrumentation scenario
runnable from the existing owned RD Gateway fixture. It does not publish `rdGateway` or `files`,
does not change product code, and does not mark F62 accepted. The host still requires the exact
named Android test, one source-built target lifetime, the target witness, and the client witness.

The candidate contains two integration pieces:

* `f62_rdpgw_owned_fixture.py run-android` replaces the generic target command with the exact
  receipted `freerdp-shadow-cli`. The fixture remains the sole owner of the generated target
  identity, writes its private SAM file, generates the target certificate used by the configured
  and live-pin comparison, starts Xvfb and the NLA-only shadow server, and keeps the existing
  network namespace, direct-target firewall, RD Gateway authentication, and cleanup rules.
* `f62_gateway_saf_android_client.py` consumes the fixture's private descriptor. It verifies a
  closed Android build receipt and the product-native APK receipt, installs the exact app and test
  APKs, sends the derived descriptor only through stdin to `adb exec-in run-as`, invokes the one
  named instrumentation method, reads at most 2,049 bytes for the 2,048-byte witness limit, and
  writes the exact client witness back to the fixture's predeclared private path.

## Source and package bindings

The real target path consumes the ten-key receipt produced by
`f62_gateway_linux_probe.py build-freerdp`. It requires FreeRDP revision
`63b948ca5cb94307fd5444ee6e73927a41ccdab4`, release archive SHA-256
`4a2629026896cb4e26fb8ed2d6ca6aa4ab89ca95528dfbae2550c2f6bc866991`, target patch
`52b61d9ecfef7c8d047ee558177ab2b0b664294729a2035c5045041a183eafb4`, target source manifest
`5a5ed427179aaad89b111c6b9bae9bc594b8c78abf7efb5e10c24ee09dfbf1f0`, witness schema 2,
device `LrnXfer`, and the exact shadow ELF digest. A command wrapper cannot stand in for the target
binary.

The Android adapter requires an external 0600 build receipt with exactly:

```
schemaVersion=1,
appApkSha256, testApkSha256,
productNativeReceiptSha256, productVerifierSha256,
sourceManifestSha256, testSourceSha256,
applicationId=com.ersingundem.larenor,
testApplicationId=com.ersingundem.larenor.test,
instrumentationRunner=androidx.test.runner.AndroidJUnitRunner
```

It then runs the receipted product APK verifier before either APK is installed. The frozen
instrumentation source manifest is rehashed file by file, and the direct test source digest is
passed as a non-secret instrumentation binding. An APK hash or an Android self-report alone is not
accepted.

## Private transport

The fixture's generic private descriptor now includes the explicit Gateway domain. The adapter
validates its exact schema and derives the frozen 23-key Android descriptor. Credentials, pins,
hosts, and ports appear only in that descriptor and are never command arguments. The only
instrumentation values are the generated nonce, frozen source-manifest SHA-256, and exact test
source SHA-256.

The device descriptor is created by a fixed `run-as` shell command with `umask 077`, exclusive
creation, and mode 0600. The Android loader independently performs `O_NOFOLLOW`, owner, link,
regular-file, mode, and length checks, deletes the descriptor before network I/O, and wipes its
password arrays. The adapter removes this invocation's descriptor and AtomicFile witness names on
every exit. Instrumentation output is bounded and retained only in a caller-selected 0600 private
log; no raw output is printed by the adapter.

## Invocation boundary

Root prepares a 0600 client command JSON whose first argument is a trusted Python interpreter and
whose remaining arguments invoke `f62_gateway_saf_android_client.py` with the exact ADB, APK,
build-receipt, product-native directory/receipt, verifier, frozen source root/manifest, private log,
and this fixture source. Root then calls `f62_rdpgw_owned_fixture.py run-android` with that client
command plus the receipted Gateway/auth binaries, `freerdp-shadow-cli`, and its full build receipt.
The expected class and method remain:

```
com.ersingundem.larenor.rdp.RdpPackagedGatewaySafAcceptanceTest
gatewaySafProvesTwoHopPinsNlaAndRdpdrRoundTripAfterExplicitDrain
```

The unchanged fixture publishes only after exact named instrumentation success, client witness
1/0/0/0, target NLA witness, 91-byte upload digest, 93-byte outbound digest, direct-target block,
two distinct pins, confirmed native drain, explicit SAF readback, and owner retirement.

## Evidence and limits

The private adapter suite exercises the complete subprocess/stdin/readback path with an owned fake
ADB endpoint, including exact receipt checks, descriptor creation, named instrumentation parsing,
bounded witness return, and 0600 private log. Separate regressions reject source tampering, changed
test APKs, stale witnesses, missing Gateway domain, duplicate/non-named instrumentation results,
and wrong target source-manifest receipts. The original fixture self-test remains green.

No Linux namespace, Gateway, shadow server, emulator, APK install, Android instrumentation, NLA,
RDPDR, or SAF effect was run here. The first hosted run must supply the actual source-built target
receipt and actual product APK receipts. Until that joined run returns the two private witnesses and
the original named 1/0/0/0 result, this candidate is pre-admission infrastructure only.
