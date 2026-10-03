# F62 public MethodChannel Gateway + SAF acceptance

This private follow-up adds a second named Android acceptance. The existing direct packaged-runtime test remains the pre-admission proof for the compiled FreeRDP v5 artifact. The new test enters through the production `RdpNativeBridge`, the `StandardMethodCodec` handlers registered by `MainActivity` on its actual FlutterEngine messenger, `RdpProductFeatureBackend`, the activity-owned SAF grant broker, transfer coordinator, and session owner.

The test first reads public capabilities and requires both `security.rdGateway` and `channels.files`. The current masked product therefore fails before credentials, picker launch, or network activity. There is no second bridge, test capability override, injected backend, or direct picker callback. The test invokes the registered production handlers and the picker result returns through `MainActivity.onActivityResult`. A test-only read of the production session pending-frame sequence permits the normal public ACK call because no Dart screen is mounted in this instrumented scenario. After a separately reviewed source admission is bound to an accepted hosted effect receipt, the unchanged test performs direct-target rejection, Gateway and target pin enrollment, persisted SAF tree selection, transfer preparation, schema-6 open, frame ACK, RDPDR effects, native drain to `sealed`, explicit save to `saved`, provider hash readback, and grant retirement.

The descriptor remains a private app-owned 0600 file delivered through `run-as`; only nonce and source/test hashes appear in instrumentation arguments. The exact target-v2 payloads are 91 and 93 bytes under `ToRemote` and `FromRemote`. The client witness stays schema 2 with the established effect-only keys and no endpoint, credential, URI, path, certificate, or payload.

The test's direct mirror read is a bounded phase barrier for the outbound write. It is not accepted as the final file effect. Final acceptance requires both the host firewall/target witness (including direct-route rejection) and the Android `sealed` -> explicit `saved` -> DocumentsProvider digest chain. After grant retirement, the test synchronously disposes the real MainActivity bridge without swallowing errors. It then uses the exact private SAF process-owner object captured from that production coordinator to acquire and immediately release a fresh probe token. `ownersRetired` is written only after this source-bound reservation proves the original coordinator released its process owner. A transport cancel or an unrelated Gateway probe is never drain/SAF-owner proof. No hosted effect run has been performed by this slice.

Flutter 3.47.2 wraps the production `DartMessenger` in `DartExecutor.DefaultBinaryMessenger`. The acceptance unwraps only that exact pinned type, reads `messageHandlers` while synchronized on the real `handlersLock`, and obtains the registered handler. Method calls and replies are flipped into readable `ByteBuffer` views before codec decoding. A focused Robolectric test instantiates the actual pinned wrapper/delegate classes and executes both this lookup and a real `StandardMethodCodec` request/reply round trip. The debug embedding JAR SHA-256 is `7e32ce0eeede5a5ac49cdde3d0b98f4743d13586da5c79d4cd519fbd7bb20dac`.

## Minimal product admission after a genuine hosted receipt

The accepted receipt must be bound to the exact current v5 engine identity, JNI schema, source patches, AARs, target-v2 source/build receipts, test source hash, named one-test result, and both host/client witnesses. Then:

1. admit Gateway and files in the reviewed product capability policy while retaining the independently verified compiled-capability intersection;
2. keep `RdpProductFeatureBackend.open` re-negotiation so a missing/wrong artifact cannot bypass admission;
3. keep ordinary sessions on schema 4, grants on schema 5, and owned Gateway/transfer sessions on schema 6;
4. run this named public-path test without overrides, plus bridge capability/open negative tests.

The AAR, engine revision, JNI schema, and lock do not change merely to admit an already accepted exact artifact.

## Truthful file status UI follow-up

The normal RDP panel currently renders the localized files-off label unconditionally. Admission must also render the actual session transfer state: active only after a bound prepared transfer opens; sealed only after confirmed native drain; saved only after explicit DocumentsProvider write and hash readback; unknown when drain or provider completion is uncertain. Unknown must retain the recovery reference and block successor reuse. It must never be presented as saved, retired, or files-off.

## Evidence commands

```sh
python3 -m pytest -q tool/tests/f62_gateway_saf_public_bridge_contract_test.py
python3 tool/f62_gateway_saf_public_bridge_contract.py verify-source --source <composed-source-root>
./gradlew :app:testDebugUnitTest --tests com.ersingundem.larenor.rdp.RdpPublicBridgeRuntimeContractTest --no-daemon --max-workers=1
./gradlew :app:compileDebugAndroidTestKotlin --no-daemon --max-workers=1
```

Compilation proves source/API compatibility only. Physical speaker/display behavior, a household server, and public capability admission remain outside this slice.

## Local evidence

- The portable source-contract suite passed 25 tests. It includes negative cases for a second/injected bridge, a replaced codec, a missing wrapper/delegate lock, absent buffer flips, admission after descriptor consumption, a fake picker route, cancel-for-drain, save-before-seal, swallowed bridge disposal, missing provider readback, and a schema-1 witness. Private log SHA-256: `c15b71be04f4376528c0ffb06a7288697e528de596c4cc548b1bdce763d39bd5`.
- `RdpPublicBridgeRuntimeContractTest` passed 2 tests with zero failures/errors/skips against the installed pinned Flutter engine. It uses the actual private constructors/fields and real codec implementation, rather than a source-token proxy. XML SHA-256: `efb0e52364f687926d89e7ff392963bd94226f9733aba2e53b48e97c925492a0`; private Gradle log SHA-256: `3fc55453014a9269396087f0f9828aaac2bae861e18d5e8bcbc256b1f9a212eb`.
- `:app:compileDebugAndroidTestKotlin` passed against the canonical generated app and exact installed native-v5 package: 276 actionable tasks (5 executed, 271 up-to-date), 14 seconds. The run excluded only `:app:compileFlutterBuildDebug`; no Dart source changed in this overlay. Private log SHA-256: `605b94c8b6790d6261c8c8d84256eda95114f6072fd757d392d5b9260fc184e4`.
- No Android/emulator Gateway effect run was performed. The named test remains intentionally red while product admission is masked.
