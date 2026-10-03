# F62 — owned Linux Gateway/RDPDR fixture, 3 October 2026

The disposable manual `f62-gateway-probe` scope builds the pinned FreeRDP
3.31.1/`63b948ca5cb94307fd5444ee6e73927a41ccdab4` target and xfreerdp client,
and pinned rdpgw `16cdaaf4dce6a6567ce9b612f14e71d0ca704148`. All source
archives, toolchain and the actual RDPDR patch are checked by SHA-256.
Target v2 patch `52b61d9ecfef7c8d047ee558177ab2b0b664294729a2035c5045041a183eafb4`,
manifest `5a5ed427179aaad89b111c6b9bae9bc594b8c78abf7efb5e10c24ee09dfbf1f0`.

The actual target uses asynchronous RDPDR IRPs for the native5 mirror paths
`\ToRemote\upload-<nonce16>.bin` and `\FromRemote\outbound-<nonce16>.bin`.
The real 91/93-byte effects and terminal target witness follow authenticated NLA
and a clean client close. Gateway and target credentials and pins are distinct;
direct target TCP is blocked. Client credentials travel through an inherited
anonymous argument FD, never command-line arguments. Exact owned network/process
cleanup precedes the only public receipt; raw logs and credentials remain private.

Root review corrected three integration issues before running Linux: use static
FreeRDP libraries so the verified code is in the named ELF binaries; copy public
checkout patch/manifest bytes into immutable 0600 workspace files for strict
package validation; negotiate bounded X.224/NLA before the target TLS pin probe.
Only the disposable mirror drive redirection is allowed in the owned gateway;
other redirection stays disabled. [Microsoft RDP negotiation contract](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/902b090b-9cb3-4efc-92bf-ee13373371e3),
[pinned rdpgw redirection policy](https://github.com/bolkedebruin/rdpgw/blob/16cdaaf4dce6a6567ce9b612f14e71d0ca704148/cmd/rdpgw/protocol/process.go).

Local root gates: 16 runner/workflow tests, 8 hardened-fixture self-tests,
6 probe self-tests, and 15 immutable target source/package tests: **45 passed**.
Ruff and actionlint passed. Fragmented/truncated/fallback NLA responses and source
copy permissions/drift are covered. Source and binary markers are not runtime
acceptance. The Android native5 packaged Gateway/SAF test compiled privately
(278 tasks) and 15 contract checks passed; it has not run against the host.

The closed Linux probe receipt binds runner Git HEAD and exact built binaries,
and explicitly declares `androidProductExercised=false`, `runtimeAccepted=false`
and `featureAccepted=false`. Linux compile/link/runtime and Android Gateway/SAF
upload/save/readback remain open. F62 is still `reworking`; no counter or merge
change is justified by these local fixture gates.

Exact `15ba7702ba6290d606dbf7cac9114719b15052c8` [37136737506](https://github.com/ersingundem/larenor/actions/runs/37136737506) completed failed before runtime: build stage `unsafeArchive`, actual job `111242689243`. Private bounded log SHA-256 `aeb7baa7042c2c067086b3f01456f119dc34b01e9a299c435233f153858ff03b`. The pinned archive is being inspected for the exact rejected member; no same-source rerun or acceptance claim.

The exact pinned rdpgw archive (`b96e24cddfdf4b6eee939dc1558734f29534c7e0ebae650858c8ba715a166907`) contains 138 entries: 108 regular files, 30 directories, no links or special entries. Its exact top-level directory has no trailing slash; that was the sole rejected header. The narrow correction accepts that exact name only as a directory. Descendants still require the source prefix; absolute paths, traversal, links and special entries remain rejected, and the immutable archive hash is unchanged. Root verified the frozen two-file manifest and old fixture byte identity, then passed 22 focused tests/15 subtests plus 8 fixture self-tests and scoped Ruff. Changed-source Linux build/runtime remains pending; this is not feature acceptance.
