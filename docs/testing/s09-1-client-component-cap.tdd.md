# S09.1 Client component-backup transport bound

Date: 23 September 2026

The merged Server backup contract permits a 128 MiB Core database, a 32 MiB
family-board database, 256 MiB of managed component data, and 8 MiB of archive
overhead: a bounded 424 MiB encrypted bundle. The Client streaming transport
still enforced the earlier 168 MiB limit. A valid component-bearing export
could therefore be rejected as `invalid_response` before it reached the
OS-owned destination.

## Acceptance boundary

1. The Client accepts the Server's 424 MiB encrypted-bundle ceiling while
   retaining 64 KiB destination writes; the Dart heap never holds the complete
   response.
2. A declared or streamed byte beyond that exact ceiling fails closed and
   cancels the partial destination. Exact response length, MIME, disposition,
   magic, digest, idle timeout, and secret-buffer cleanup remain unchanged.
   The total deadline is 15 minutes so the larger bound remains usable on a
   realistic connection while retaining a finite ceiling.
3. This slice changes no Server decode/restore code, native destination code,
   K03/media code, queue state, or progress counter.

## TDD evidence

After generating the repository's checked models, the focused RED test was:

```text
flutter test test/features/server/server_core_backups_test.dart \
  --plain-name 'export accepts 424 MiB cap as bounded reused chunks'
```

It failed with `LarenorServerException(invalid_response)` at the old declared
length guard. The GREEN full-file rerun passed **15 tests** in about two
seconds, including the 424 MiB reused-chunk boundary, declared overflow,
length mismatch, cancel/late-write, dispose, error response, passphrase
scrubbing, and restore-preflight regressions.

## Remaining S09.1 gates

S09.1 remains pending. Privileged component capture, component restore and
rollback, interruption recovery, Client restore/import UX, native acceptance,
independent review, and exact-head CI remain open. Queue and selected-feature
counters stay at **25/125** and **0/63**.
