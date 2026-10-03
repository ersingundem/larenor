# F60 owned launch RI-key package contract — 2026-10-03

## Problem and boundary

The pinned Moonlight `Game` constructed its own `NvConnection`, and that constructor generated a fresh remote-input AES key and key ID. Larenor's authenticated provider launch already used a different one-use key pair. The launch request and the subsequent RTSP/input connection therefore could not be proven to share the same RI key. This package change adds a process-private construction seam; it does not expose RI material through an `Intent`, MethodChannel, DTO, receipt, journal, or log.

## Source-locked API

Engine revision `moonlight-android-12.2-larenor-embed-v5` keeps the existing seven-argument `NvConnection` constructor unchanged. Pinned `Game.onCreate` now calls this protected factory:

```java
protected NvConnection createConnection(
    Context appContext,
    ComputerDetails.AddressTuple host,
    int httpsPort,
    String uniqueId,
    StreamConfiguration config,
    LimelightCryptoProvider cryptoProvider,
    X509Certificate serverCert)
```

The default factory calls the existing constructor. An embedded subclass may override it and call the added constructor:

```java
public NvConnection(
    Context appContext,
    ComputerDetails.AddressTuple host,
    int httpsPort,
    String uniqueId,
    StreamConfiguration config,
    LimelightCryptoProvider cryptoProvider,
    X509Certificate serverCert,
    byte[] remoteInputAesKey,
    int remoteInputAesKeyId)
```

The explicit key must be exactly 16 bytes and the ID must be in Java's nonnegative signed range. The constructor clones the supplied bytes, constructs an AES `SecretKeySpec`, and wipes its temporary clone. It never retains the caller's byte array. The embedded caller remains responsible for wiping its one-use lease bytes after the constructor returns or throws.

The key ID is serialized by pinned Moonlight as decimal `rikeyid` for launch and as a four-byte big-endian Java `int` in the RTSP initialization vector. This package adds no unsigned or sentinel interpretation.

## Package evidence

The source lock binds the third patch and the transformed `Game.java` and `NvConnection.java` blobs. The package receipt requires both exact JVM descriptors: the protected factory and the public explicit-key constructor. A legacy AAR lacking either descriptor fails with `missing_engine_api`. Source verification also requires the exact factory call, 16-byte/nonnegative guards, caller-array clone, AES import, temporary wipe, and private context assignment.

A private dual-ABI build completed with 33 Gradle tasks and produced an AAR
containing only `arm64-v8a` and `x86_64` Moonlight native libraries:

- patch SHA-256: `2453816189554e3f1d78b79457830b5b80bf6686a32ee686201ab5b9dcb941f8`;
- transformed `Game.java` Git blob: `4c91c7cf7a3f00fcdd0de681809a859273755371`;
- transformed `NvConnection.java` Git blob: `de84a2995b934a3a8ac99dd20937908de4f16d76`;
- AAR SHA-256: `ec3e8fc3023848046e38e2ceefcb482a15e9c91895e5a247de47e6a0c6d759a5`;
- receipt SHA-256: `2000bb39fddac16f9027fae62732767d2d277ff786cad47f6c552737a1d348db`;
- deterministic source-bundle SHA-256: `f92e87bc268b22a69c3e78f375f74e4733bb373c13d851c46f1e4cc5a2aee2c6`.

`verify-source`, exact three-patch preparation, `verify-install`, and 13 package
tests passed. The previous v4 AAR was rejected with `missing_engine_api`, while
`javap` on the v5 AAR confirmed both exact descriptors and access levels.

This evidence proves package identity and the construction API only. Actual F60
acceptance still requires the owned host to observe the strict launch, RTSP,
decoded output, input, stop, and retirement gates.
