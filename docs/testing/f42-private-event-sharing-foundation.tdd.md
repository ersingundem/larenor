# F42 privacy-preserving event sharing Core foundation

Status: **Core contract ready; F42 remains pending**

The package is provider-neutral. It does not claim to run a Frigate, camera or
video processor. Instead it accepts a closed, keyed transformation receipt from
an explicitly trusted local redaction worker and exposes only the resulting
sanitized artifact.

## Three accepted criteria

1. **Explicit consent and verified transformation scope.** A share binds an
   exact recipient, purpose, event, access mode and expiry to a versioned
   consent. The transformation receipt binds source/output digests, output
   artifact, pipeline revision, face/license-plate mask set and removed metadata
   set under an HMAC proof. Missing required masks/metadata, unchanged output,
   altered proof, recipient, purpose or expiry fail closed. No original artifact
   reference enters the public model.
2. **Bounded access and exact authority.** Create/revoke commands bind Core,
   home, account, member, camera, event and session revisions plus the current
   share revision. Byte-changed reuse of a command ID conflicts. One-time links
   reject a second access; time-bound links expire and both modes reject after
   revocation. Token, access and event counts are bounded and each accepted
   mutation advances the keyed audit chain.
3. **Encrypted persistence and secret-free inspection.** Share payloads and
   access tokens are AES-256-GCM encrypted with scope-bound associated data;
   keyed payload/token fingerprints, strict schema validation and an HMAC
   event/state chain detect restart tampering. Creator/admin reads are bounded.
   Export omits tokens, source digests, transformation proofs, nonces,
   ciphertext and keys while retaining recipient, expiry, sanitized artifact,
   mask/metadata proof summary, consumed and revoked status.

## Evidence

- RED `c2ed1433`: the package import failed before production code existed.
- GREEN `d596328c`: three focused pytest scenarios pass for consent/proof,
  one-time/time-bound/revoke/idempotency, encrypted persistence, role isolation,
  secret-free export and audit tampering.
- Python compilation, security policy, execution queue, progress trailers,
  diff, redacted secret scan and merge-tree are final PR gates.

## Remaining boundary

F42 and the progress counters stay unchanged. A concrete local video-redaction
worker, HTTP/Android surfaces, isolated Client-to-Core E2E, Frigate fixture and
visual verification of real face/plate masks remain later acceptance packages.
The signed receipt is evidence from a trusted worker, not visual proof created
by this foundation itself.
