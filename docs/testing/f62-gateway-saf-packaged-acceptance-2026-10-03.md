# F62 packaged Gateway and SAF acceptance candidate (2026-10-03)

## Scope

This private overlay adds a separate named Android instrumentation scenario for the receipted
FreeRDP schema-5 package. It does not alter production code, public capability publication, or the
ordinary schema-4 host baseline. `rdGateway` and `files` remain unavailable to the product until the
real joined host/client acceptance described here passes against the exact installed AAR receipt.

The positive method is
`RdpPackagedGatewaySafAcceptanceTest.gatewaySafProvesTwoHopPinsNlaAndRdpdrRoundTripAfterExplicitDrain`.
One fixture process runs one authenticated target lifetime. Negative methods require fresh fixture
processes and cannot be multiplexed into that lifetime.

## Private descriptor transport

The host client adapter reads its existing 0600 `LARENOR_F62_RDGW_DESCRIPTOR`, validates the pinned
fixture and target receipts, and derives a closed device descriptor. It writes the bytes through
stdin only to:

```
adb shell run-as com.ersingundem.larenor sh -c \
  'umask 077; cat > files/f62-owned-gateway-saf-<nonce>.json'
```

No password, host, port, pin, or provider URI is an argv or instrumentation argument. The test
receives only `rdpGatewaySafNonce`, `rdpGatewaySafSourceSha256`, and
`rdpGatewaySafTestSha256`, each a lower-case 64-hex non-secret binding. Before opening any network
operation it opens the descriptor with `O_NOFOLLOW`, requires a regular one-link current-UID 0600
file of 1..4096 bytes, validates the exact nonce/source/test binding and closed JSON schema, deletes
the file, and verifies that it is gone. Passwords are held only in private mutable arrays after
parsing and are wiped on every exit. No descriptor value is logged or placed in a failure message.

The derived device descriptor has exactly these keys:

```
schemaVersion, nonce, sourceSha256, testSha256,
fixtureSourceSha256, targetPatchSha256, targetSourceManifestSha256,
gatewayHost, gatewayPort, gatewayUsername, gatewayPassword, gatewayDomain, gatewayPin,
targetHost, targetPort, targetUsername, targetDomain, targetPassword, targetPin,
expectedUploadSha256, expectedOutboundSha256
```

This adapter remains an integration item owned by the root runner. The candidate test is not
runnable until that adapter binds the current test source receipt and installed AAR receipt.

## Real effect chain

1. A test-APK `DocumentsProvider` exposes one private tree with `ToRemote` and `FromRemote`.
   The test APK grants the target app read, write, prefix, and persistable URI permission. The real
   schema-5 grant broker takes it and readbacks a persisted read/write grant.
2. The provider contains `upload-<nonce[0:16]>.bin` with ASCII
   `Larenor-F62-Gateway-upload:<nonce>` (91 bytes). The real SAF adapter copies it into a private
   0600 mirror before the schema-6 open.
3. The packaged runtime first proves the target cannot be reached directly. It inspects the Gateway
   certificate, then authenticates only the pinned Gateway to inspect the separately pinned target.
   Target and Gateway credentials and pins remain distinct.
4. The exact planned schema-6 session owner opens with a real transfer endpoint and fixed private
   drive `LrnXfer`. The native RDPDR server reads
   `\\ToRemote\\upload-<nonce[0:16]>.bin` to EOF, validates its digest, and creates
   `\\FromRemote\\outbound-<nonce[0:16]>.bin` containing ASCII
   `Larenor-F62-Gateway-outbound:<nonce>` (93 bytes).
5. The Android test observes that exact native mirror effect, acknowledges a real frame, then calls
   `drainFileTransfer`. Only a `sealed` receipt after
   `RdpNativeSession.closeAndAwaitNativeDrain() == true` is accepted. Generic cancel/close is never
   drain proof.
6. Only after seal, explicit `saveReceivedFiles` creates/writes the provider document and performs
   exact size and SHA-256 readback. The grant is explicitly retired and the persisted permission is
   proven absent.

The host independently requires the source-bound target witness:

```
schemaVersion, nonce, authenticatedSessions=1, nlaAuthenticated=true,
uploadSha256, outboundSha256, outboundClosed=true, cleanClose=true
```

The Android private witness is nonce-bound, uses `schemaVersion=2`, and contains only:

```
schemaVersion, nonce, testClass, testName, tests=1, failures=0, errors=0, skipped=0,
directTargetBlocked, gatewayPinMatched, targetPinMatched, frameAcknowledged,
nativeDrainConfirmed, safReadbackSha256, ownersRetired
```

The runner may publish success only after exact named JUnit 1/0/0/0, the installed AAR receipt,
this source receipt, the target patch/source receipt, both private witnesses, and both expected
digests agree. Neither Android self-report nor the target witness is sufficient alone.

## Joined publication receipt

The raw host effect receipt remains schema 2 and always keeps `featureAccepted=false`. Before an
artifact is published, `f62_gateway_android_hosted.py join-receipt` validates that effect receipt
against the private launcher, Android build, and source manifests and writes a new O_EXCL 0600
schema-3 joined receipt. It preserves the exact scenario class/name, 1/0/0/0 counts, all effect
facts, Gateway source/binary facts, scope, and the false acceptance flag. It additionally binds:

```
checkoutRevision, checkoutTree, effectReceiptSha256, launcherReceiptSha256,
androidBuildReceiptSha256, appApkSha256, testApkSha256,
productNativeReceiptSha256, productVerifierSha256, sourceManifestSha256,
testSourceSha256, targetPatchSha256, targetSourceManifestSha256
```

All identities are fixed 40-hex Git object IDs or 64-hex SHA-256 values. The join rejects an
unknown/extra key, wrong scenario, non-exact named result, inconsistent private receipt hash,
source/test drift, target binding drift, or any acceptance claim. The PUBLIC source manifest also
requires the real `MainActivity`, native bridge, product admission wrapper, request/engine/runtime
sources, packaged runtime, and `freerdp-native.lock.json`; hashing only the test/provider is not a
normal-path source proof. The registered workflow must upload this joined receipt, while raw logs,
descriptors, credentials, provider paths, and private manifests stay private.

## Negative invocations

`gatewaySafRejectsWrongGatewayPinBeforeCredentials` uses a fresh target process, mutates only the
expected Gateway pin, requires probe failure, and requires confirmed native probe drain. It cannot
consume or precede the positive target lifetime. `gatewaySafPickerCancellationDoesNotPersistOrPrepare`
uses the real grant broker/provider, cancels the exact pending request, and proves no persisted grant;
a late unrelated result is rejected. Wrong target pin and wrong authentication should be added as
separate fresh-process invocations when the runner has closed failure receipts for them. They must
not be inferred from the positive test or replace the positive effect gate.

## Current evidence and limits

The portable source validator checks that the candidate keeps the packaged runtime, two-hop probes,
real broker/coordinator/provider, exact payload lengths/names, frame ACK, confirmed drain, explicit
save readback, retirement, and closed witness. It rejects fake runtimes, acceptance overrides,
mirror-only completion, generic close as drain, weak provider modes, and non-persistable manifests.

The target v2 binding used by the candidate is patch SHA-256
`52b61d9ecfef7c8d047ee558177ab2b0b664294729a2035c5045041a183eafb4` and source-manifest
SHA-256 `5a5ed427179aaad89b111c6b9bae9bc594b8c78abf7efb5e10c24ee09dfbf1f0`.
The focused portable contract suite currently passes 15 tests. These hashes remain host-side
source/build bindings and are deliberately absent from the session/effect-only client witness.

No Android test, Gateway session, RDPDR transfer, DocumentsProvider effect, or device acceptance was
run in this slice. Root owns disposable composition, exact AAR binding, Linux fixture build, client
adapter, hosted execution, and final public receipt. Physical speaker/display/device validation is
unrelated and remains manual where already documented.

The candidate's production/native5 composition was compiled in an APFS-cloned private project with
an isolated Gradle home. `:app:compileDebugAndroidTestKotlin` completed successfully in 20 seconds:
278 tasks, 7 executed and 271 up-to-date. The private log is
`/private/tmp/larenor-f62-gateway-saf-compile-20261003-a/compile-2.log`, SHA-256
`6f72da229c1b2317c31b69649b0b799533429ab46d23dcc36ee35b04105f9492`.
This proves compilation only. The hosted fixture must still enable drive redirection explicitly
(`DisableRedirect=false`, `EnableDrive=true`, every unrelated redirect disabled); the current
fixture default disables drive redirection and cannot satisfy this effect gate until root applies
that source-bound launcher correction.
