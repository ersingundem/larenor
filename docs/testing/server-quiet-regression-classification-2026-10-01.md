# Server quiet-host regression classification — 2026-10-01

The local full Server run was interrupted at approximately 80% after the
test host ran out of disk space. Its private log is retained. That run is
invalid as a broad acceptance result; the 17 additional failure/error marks
after disk exhaustion are not classified as production defects.

Before disk exhaustion, five failure marks were observed: one F22
continuous-execution/access-expiry case, two F35 PDF/OCR cases and two
host-worker plugin-artifact permission cases. The plugin-artifact defect
was independently reproduced under `umask 077` and repaired; its
[focused proof](host-worker-plugin-artifact-mode-2026-10-01.md) is separate.

After disk and CPU recovery, with no active broad pytest, Flutter or Gradle
build, the exact F22 case passed once and both exact F35 HTTP cases passed.
The targeted retries used the unchanged F22/F35 source present at
`e73e42676b547a9fa7bb0755bfaa8b81550677fd`. No F22/F35 production change or
deadline increase was made. The existing direct production OCR pipeline
probe had also produced a valid candidate from the same public synthetic PDF.

These three passing retries do not prove the exclusive cause of the earlier
failures. They establish that no deterministic source defect was reproduced
under quiet conditions. F22/F35 therefore return to **CI waiting**: their
development and focused gates are complete, while broad final-HEAD Server
acceptance remains open. They do not advance the accepted counters.

Private focused logs, both mode `0600`:

- `/private/tmp/larenor-quiet-f22.log`
- `/private/tmp/larenor-quiet-f35.log`

The full interrupted log is
`/private/tmp/larenor-f57-full-server.XXXXXX.log`. Physical devices and actual
household providers remain outside these synthetic fixture checks.
