# F62 bounded linker failure diagnostic

The exact `7e6d276943a1a34821e7b241ea2e3c5ff0428987` Linux probe produced a
source-bound build failure receipt with `phase=compile`,
`failureCode=linkerError`, `compilerErrorClass=linkUndefined`, exit code 1,
and `featureAccepted=false`. The retained receipt did not identify which of
the two requested executables failed. Its private compile log had already been
deleted, so the actual target and missing symbol remain unknown.

This slice changes only failure reduction. Schema 4 retains every existing
archive, source, patch, manifest, runner, log, phase, exit, and non-acceptance
binding and adds a closed linker tuple:

- `linkTarget` is one of `shadowCli`, `xFreeRdp`, `multiple`, or `unknown` and
  is derived only from exact Ninja `FAILED:` output suffixes for the two
  executables requested by this probe. A multi-output `FAILED:` record is
  accepted only when every output maps to one of those exact targets.
- `linkUndefinedCount` is `null` for an unknown diagnostic or a bounded integer
  from 1 through 255. `linkUndefined` contains at most four unique identifiers,
  represented only by SHA-256 and one of `ownedRdpdrApi`, `x11External`,
  `cryptoExternal`, or `other`.
- The owned class contains only `rdpdr_server_context_new` and
  `rdpdr_server_context_free`, reviewed in the pinned RDPDR server headers and
  implementation. The X11 class contains four Xlib calls referenced by the
  pinned X11 client/shadow sources. The crypto class contains six OpenSSL calls
  referenced by the pinned TLS, certificate, HTTP, and Schannel sources.
- `linkOriginSource`, `linkOriginLine`, and `linkOriginSourceSha256` are either
  all null or a finite source class, a valid line, and the digest from the
  archive/manifest source index. The private repo-relative path is used only
  internally to re-read and verify the indexed source and is never published.

Any malformed quote, oversized line, non-ASCII identifier, unreviewed or
contradictory target, missing `FAILED:` record, or absent symbol record reduces
the complete linker tuple to `unknown`/null/empty. Source drift with an
otherwise valid target and symbol withholds only the origin tuple. Neither
condition suppresses the original build failure receipt. Raw symbols, paths,
linker messages, build output, endpoints, and credentials are never included.

The probe configures Ninja with `RelWithDebInfo` and static FreeRDP libraries,
then requests both executables in one `cmake --build` command. The reducer
therefore recognizes three bounded GNU ld shapes: an indexed source and line
with an optional section offset, an archive/member or object prefix with an
optional section offset, and a bare undefined-reference record. Archive and
object prefixes are never published and cannot create a source-origin tuple;
only a current archive/manifest-indexed source and valid line can do that.

The success path and cleanup order are unchanged. This diagnostic cannot make
the probe accepted and does not establish whether owned RDPDR linkage, static
X11 linkage, crypto linkage, or another dependency caused the historical
failure. A changed-source Linux execution is still required to observe a real
tuple, and the complete Gateway/RDPDR feature still requires its separate
owned effect and Android product acceptance gates.

Private focused verification on 2026-10-03:

- `51 passed, 9 subtests passed` for the two focused probe/diagnostic test
  files.
- Python bytecode compilation passed for the runner and both focused tests.
- Ruff passed for the same three Python files.

No build, Gradle task, Git mutation, CI dispatch, provider connection, or
household-device operation was performed.

Root independently verified the frozen base/candidate/patch hashes, inspected the GNU ld reducer and closed receipt writer, and ran the focused gate: **51 passed,9 subtests passed**. Same source failure was not rerun; a new changed-source exact Linux run is required.
