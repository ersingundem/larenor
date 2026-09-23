# S09.1 Client contract-version coherence

Date: 23 September 2026

The Client accepted each known backup contract version, resource set, and
resource version individually, but selected the component-era shape from the
presence of optional keys. A stale or malicious Core response could therefore
mix version 1 and version 2 fields and still become a trusted restore-preflight
manifest.

## Acceptance boundary

This narrow Client slice closes three version-shape checks:

1. Contract version 1 accepts only the seven legacy manifest fields and rejects
   component-era fields, component declarations, or a consistency boundary.
2. Contract version 2 requires the exact nine-field component-era shape,
   including the `components` list and consistency-boundary field.
3. Contract version 2 requires a non-null, exact consistency boundary;
   `component-index` version selection is bound directly to the contract
   version rather than inferred from nullable boundary state.

The canonical four-resource version 1 manifest and current version 2 manifest
remain accepted. Mixed shapes fail with the existing static
`invalid_response` classification. Serialization emits the exact field set for
the parsed contract version. No resource digest, path, payload, or backup
secret enters an error or model string.

## TDD evidence

Three RED regressions proved that the old parser accepted a version 1 manifest
with component-era fields, a version 2 manifest missing both component fields,
and a version 2 manifest carrying an explicit null consistency boundary. All
three are rejected after the GREEN change.

The focused model/controller test passes **21 tests**. The broader Client
backup model, screen, quiescence, and file-access group passes **40 tests**.
Focused Dart formatting and Flutter analysis pass. The repository policy suite
passes **383 tests** with four documented native-fixture skips; security,
queue, progress, and diff checks also pass.

## Remaining S09.1 gates

S09.1 remains pending. Production component restore and rollback, interruption
recovery across component effects, native/provider acceptance, independent
review, and exact-head CI remain separate gates. This slice does not change
`docs/PROGRESS.md`, `docs/execution-queue.json`, or the counters **26/125** and
**0/63**.
