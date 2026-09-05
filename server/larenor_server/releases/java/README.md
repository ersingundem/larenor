# Release APK verifier

Larenor Server must validate the uploaded APK before publication. `VerifyApk.java` is a small Larenor helper using the official Android `apksig` verifier and binary manifest parser. It never installs the APK, loads its classes or invokes code from the archive. The client independently verifies the downloaded APK against its own installed package and current certificate.

Runtime: Java 17 or newer, with a 256 MiB Java heap and a 90 second verification deadline. Unsupported APKs fail closed. The policy supports one signer, a complete APK, literal versionName and Android API 26–37. Key rotation/multiple signers/split APK delivery need a separate policy and are not implicitly accepted.

Pinned dependency:

- Maven coordinate: `com.android.tools.build:apksig:9.1.0`.
- Artifact: https://dl.google.com/dl/android/maven2/com/android/tools/build/apksig/9.1.0/apksig-9.1.0.jar
- SHA-256: `562cd0a88890960d2ece48e116c61f12872222f1dcc306890799382bc019b201`.
- Upstream source: https://android.googlesource.com/platform/tools/apksig/
- Upstream license: Apache License 2.0. Larenor's source license does not replace this dependency's license. Preserve the dependency's license/notice in redistributions (see also `android/app/src/test/resources/updater/LICENSE.apksig`).

Build with an already downloaded, hash-verified artifact:

```sh
javac -cp /opt/larenor/apksig-9.1.0.jar -d /opt/larenor/verifier-classes server/larenor_server/releases/java/VerifyApk.java
```

Configure `JavaApkVerifier` with absolute, operator-controlled Java, artifact and class-directory paths. Runtime verifies the artifact hash on every verification. Neither a request nor release metadata can choose a command or verifier path. Root-owned read-only container files are recommended; the server's data volume is separate.

`test_releases_verifier.py` compiles this helper and verifies a real, hash-pinned AOSP signed fixture; altered content, wrong signer/policy, duplicate manifest and a missing verifier are negative cases. Set `LARENOR_TEST_APKSIG_JAR` and provide `java`/`javac` for these tests. Missing prerequisites fail tests rather than silently skipping cryptographic coverage. Fixture provenance and Apache license are retained alongside the fixture. The fixture is never installed or executed.
