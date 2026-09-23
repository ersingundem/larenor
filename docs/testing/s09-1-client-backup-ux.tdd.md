# S09.1 Client encrypted export and restore preflight

23 September 2026. This narrow Client slice starts from `origin/main`
`54abbf347d70234f1012f767cb39fadd5e3a09f1`. It exposes the existing Core
backup contract to an authenticated tablet administrator without adding a live
restore or any host-volume write.

## Acceptance boundary

1. **Bounded encrypted download.** The Client posts a 16–128 character
   passphrase only in the JSON body of the fixed `/admin/backups/export`
   endpoint. It accepts at most 168 MiB and requires the exact encrypted-bundle
   MIME type, attachment filename, `no-store`, `nosniff`, and format marker.
   The OS owns the chosen destination; the app does not stage plaintext or a
   temporary export file.
2. **Fail-closed manifest preflight.** The tablet sends only the already
   bounded plan manifest to `/admin/backups/restore/validate`. Unknown,
   duplicate, malformed, or incoherent reasons are rejected. Contract, Core
   version, database schema, and component schema mismatches have separate
   English and Turkish labels. This action does not upload a bundle, call a
   restore endpoint, or write a device/host volume.
3. **Current authority and accessible layout.** Account, PIN, foreground,
   visible-route, and controller generations guard both actions. Retired export
   and preflight results cannot update the screen or start a file save. Secret
   fields are obscured and cleared on completion, lifecycle expiry, or dispose;
   response and error models never retain the passphrase. Widget coverage runs
   in English and Turkish at 600 and 1200 logical-pixel widths with 2× text.

## TDD evidence

The RED checkpoint is `1c0354e1`. After generated-code setup, the focused run
failed only because the binary export, compatibility reasons, stale-result
suppression, and OS destination surface did not exist. The GREEN focused run
passes **17 tests** in `server_core_backups_test.dart` and
`server_core_backups_screen_test.dart`; the changed Client files are
analyzer-clean. Focused coverage records **40/49 lines (81.6%)** for the new
bounded transport method; the Core backup controller, model, API, and screen
remain above 85% line coverage. Queue validation still reports **23/125**
tasks and **0/63** selected features.

## Remaining S09.1 gates

S09.1 remains pending. Managed component-volume payloads and their lifecycle,
an imported old-bundle manifest flow, empty-Core restore apply/rollback,
interruption recovery, Android emulator/SAF acceptance, independent review,
and exact-head CI remain separate gates. This slice does not change
`docs/PROGRESS.md`, task status, or evidence-backed counters.
