# S09.2 empty Core restore foundation

Date: 2026-09-21

This stacked foundation restores an authenticated S09.1 bundle only into an
empty Core target. The CLI reads both the bundle and passphrase from private
files, decrypts and validates the complete resource set before staging, starts
all Core services against the staged database/key pair, checkpoints SQLite,
then journals publication of the two files. Normal Core startup completes an
interrupted journal before it can initialize or accept traffic.

The package rejects a wrong passphrase, truncation, authenticated tampering,
Core/schema/component incompatibility, existing or non-empty targets, malformed recovery
journals and mismatched staged or published digests. Errors use static codes;
the passphrase and decrypted configuration never enter output or the journal.

## Acceptance evidence

- The original eight restore tests cover two restarts with the same Core identity, admin
  login, encrypted connection document and vault key; three authentication
  failures with zero published state; pre-stage incompatibility; interruption
  after the key move followed by startup recovery; non-empty refusal; and the
  private-file CLI boundary.
- Two journal fault tests cover a failed journal write (staged secrets removed,
  empty target reusable) and a failure after atomic journal promotion (startup
  completes the restore). The journal is written and synced in the private
  stage before publication, so a partial journal cannot become authoritative.
- The broader backup, CLI, Core context and storage set passes 67 tests.
- Queue, commit-progress and security policy suites pass 50 tests. Ruff is
  clean for the new/changed surface except the pre-existing unsorted import
  block in `core.py`, which is checked with I001 excluded to avoid unrelated
  file-wide churn. Python compilation and `git diff --check` are clean.

This is software evidence only. S09.2 remains pending until the prerequisite
S09.1 changes land, the stacked branch is rebased, independent review and CI
pass, and the complete task is closed in the execution queue.
