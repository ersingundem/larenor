# F62 gateway target compiler-location diagnostic

## Observed hosted boundary

The exact `3f23132ffc4ac151ee2ad3f35fc9e274a3c0e573` run produced the canonical
closed receipt with one bounded fact: configuration completed and the compile
command exited `1`, classified as `compilerError`. The receipt is bound to
FreeRDP `63b948ca5cb94307fd5444ee6e73927a41ccdab4`, archive SHA-256
`4a2629026896cb4e26fb8ed2d6ca6aa4ab89ca95528dfbae2550c2f6bc866991`,
target patch SHA-256
`52b61d9ecfef7c8d047ee558177ab2b0b664294729a2035c5045041a183eafb4`,
and target source-manifest SHA-256
`5a5ed427179aaad89b111c6b9bae9bc594b8c78abf7efb5e10c24ee09dfbf1f0`.
The private compiler log was intentionally deleted during cleanup. No filename,
line, symbol, or compiler message survives, so this receipt does not prove that
the new RDPDR target source was the failing translation unit.

## Source review

The reviewed target callbacks match the pinned `RdpdrServerContext` function
types, including distinct three-argument `ReceiveDeviceRemove` and two-argument
`OnDriveDelete` callbacks. A local syntax-only compilation used the exact
manifest-bound patched `shadow.h`, target source, pinned headers, and generated
FreeRDP configuration. Both `shadow_owned_rdpdr.c` and `shadow_channels.c`
completed with no type or declaration error. This is useful source/API evidence,
but it is not the hosted Linux build and does not identify the hosted failure.
Changing the target patch from this evidence would therefore be speculative.

## Proposed changed-source diagnostic

Failure receipt schema 2 retains all prior hashes, exit status, and
`featureAccepted:false`, and adds exactly three closed fields:

- `compilerSource`: a fixed enum for the six manifest-reviewed target units, or
  `null`;
- `compilerLine`: a bounded line number only when that fixed unit is recognized,
  otherwise `null`;
- `compilerErrorClass`: one of `missingHeader`, `undeclaredIdentifier`,
  `missingMember`, `incompatibleType`, `callSignature`, `syntaxError`,
  `linkUndefined`, `other`, or `null`.

The parser operates on bounded bytes and never decodes or publishes a compiler
message, path, hostname, symbol, credential, or provider value. Unknown files,
out-of-range lines, truncated records, and malformed tuples remain `null`. The
private log hash remains present, and cleanup still removes the private raw log.
The diagnostic cannot make a failed build successful and is not runtime or
feature acceptance.

## Focused proof

The private overlay's focused Python gate passes 29 tests. Regressions cover
fixed-unit classification, private path/message exclusion, non-ASCII bytes,
unknown source, out-of-range line, truncated diagnostic, linker-only failure,
malformed receipt tuples, prior failure classes, successful-build absence, and
private receipt/log modes.

Root review adds fail-closed rejection for a bound source with no line, rejects a truncated over-512-byte compiler message, and only extracts location tuples for the matching compiler/header/linker failure families. Root 51 focused runner/archive/workflow tests plus 8 subtests and scoped Ruff passed. The target patch and source manifest stay unchanged because the pinned API/syntax review did not prove the hosted compiler cause.
