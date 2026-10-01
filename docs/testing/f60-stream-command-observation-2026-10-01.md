# F60 stream-command observation diagnostic (2026-10-01)

Run `36819571890` at source revision
`57f929459a22ab6082e400194e31e0162545f672` reached the exact owned Sunshine
pairing and catalog boundary, then failed the named Android test with one test,
one failure, zero errors, and zero skips. The first stream command returned the
public fail-closed tuple `unknown/unknown/unknown`; the strict rendered-frame,
PCM, input, second-lifetime, disconnect, and local-retirement gates therefore
did not pass.

That public tuple does not identify a provider cause. Production collapses
pre-launch rejection, launch failure, transfer expiry, a terminal unknown lease
observation, and the fixed 30-second command deadline to the same receipt. The
new diagnostic keeps that deadline and every acceptance assertion unchanged.
On an exact first-stream failure it records only:

- the bounded command state, result, and observation-kind enums;
- the exact process-private lease state exposed by the current runtime as one
  of `transferPending`, `gameVisible`, `uncertain`, `retired`, or
  `absentOrUnreadable`;
- a matching fixed classification and the literal `strictFailure` outcome.

The Python publisher accepts the marker only from the exact named test, exact
source hash, exact owned source frame, and a one-test failure with zero skips.
Wrong test identities, stale source, mismatched enum/classification pairs, and
extra marker fields are rejected. Nonces, PINs, provider addresses, host or app
identifiers, certificates, launch tokens, raw callbacks, and native payloads
are never published.

This is diagnostic evidence only. It does not establish a Sunshine or
Moonlight defect, extend a timeout, relax a provider check, or satisfy F60
software acceptance. A changed-source hosted run is required to observe which
bounded runtime state accompanies a real failure.

Root focused runner/workflow regression: **59 passed**. Exact AndroidTest
Kotlin compilation reported **BUILD SUCCESSFUL**, 278 tasks; the source-bound
test SHA-256 is
`bda887056886c53c147651a35473cf1120284009367481131dd41469490327ea`.
The pinned Ruff check found three unused imports, removed before the final
repeat. These are diagnostic/compilation checks, not stream acceptance.
