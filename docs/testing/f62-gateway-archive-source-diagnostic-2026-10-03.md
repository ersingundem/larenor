# F62 Gateway archive-source compiler diagnostic

Run `37139430213` at exact source `f0ded7f538853fdb7a6afd31d000dc1fdc6e5cfb` again failed in the FreeRDP compile command. Its closed receipt is 644 bytes with SHA-256 `d7c6b7b8d4d6dde3b2d9c75184c02fc71b753fc9c4c11eace3079496520daa2d`. It reports `phase=compile`, `failureCode=compilerError`, `exitCode=1`, and `featureAccepted=false`, but all three compiler-location fields are null. The receipt binds the private log with SHA-256 `cc83d52626215ee8e7049a015ce68ba7ecd35afd825b54002f4bf5e0a061b40b`. It does not prove which translation unit failed or what repair is needed, so the same source should not be rerun and the six reviewed target units should not be changed speculatively.

The previous diagnostic recognized only six manifest-reviewed target basenames. A normal pinned FreeRDP build compiles many other upstream units, so basename-only matching cannot locate an error elsewhere and could confuse an external file that happens to share a reviewed basename.

The changed diagnostic builds an in-memory source index immediately after extracting the SHA-256-verified FreeRDP archive. The index admits at most 20,000 nonempty regular, private source/header files with a finite suffix and ASCII relative-path grammar. Empty source units are ignored because no positive compiler line can identify them. Every admitted entry stores its content SHA-256 and exact line count. After the reviewed target patch is applied and its manifest is verified, only exact manifest-bound paths are refreshed with their required patched digest. An unexpected patch mutation retains the original index digest and therefore cannot be published.

Compiler output is reduced only when one complete bounded record contains:

- an absolute path strictly under the exact extracted source root, or an exact safe archive-relative path;
- a path present in the private index;
- a current no-follow file digest and line count equal to the indexed identity;
- a line number within that exact file; and
- one fixed error category.

Schema 3 retains the existing source/archive/patch/manifest/log hashes and nonacceptance flag. It adds `compilerUnit`, the public upstream archive-relative path, and `compilerUnitSha256`. The existing `compilerSource` stays a fixed enum for the reviewed target units and uses `archiveSource` for other exact indexed files. Unknown, external, traversal, non-ASCII, overlong, incomplete, out-of-range, mutated, or unindexed records remain null. No compiler message, symbol, private root, endpoint, credential, provider value, or raw build output is published.

The complete compile log remains a `0600` file in the disposable private workspace until classification and receipt fsync finish. The workflow still copies only the closed receipt and removes the private workspace; it does not upload the raw log.

The pinned archive contains 1,740 files with an admitted suffix, including two empty units; its largest such unit is 815,203 bytes and none exceeds the count, path-length, or 8 MiB bounds. The focused diagnostic suite passes 30 tests, and the combined diagnostic, probe, and workflow suites pass 46 tests plus 3 subtests. Portable tests exercise a generic archive source, an exact manifest target source, empty-unit exclusion, absolute and relative paths, current-file hash validation, line bounds, external same-name rejection, traversal, unknown units, non-ASCII paths, overlong and incomplete messages, concurrent compiler/linker output, closed error classes, receipt tuple consistency, private modes, cleanup ordering, and unchanged build-failure behavior. These tests do not compile FreeRDP and do not establish Gateway, RDPDR, Android, or feature acceptance.

Root integration independently verified all three source hashes, ran the combined 46-test/3-subtest diagnostic gate and the additional 4-test/5-subtest archive gate, and passed scoped Ruff. Independent review found no concrete P1/P2 trust or privacy defect. The change remains a diagnostic, not a source repair or runtime acceptance.
