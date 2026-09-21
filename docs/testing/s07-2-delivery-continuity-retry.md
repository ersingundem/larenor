# S07.2 delivery continuity and retry acceptance

This slice closes the three software evidence gaps found in the S07.2 audit.
Its S07.1 dependency, independent review, and CI evidence are bound in
`docs/s07-2-s07-3-software-closure-2026-09-21.md`.

| Acceptance | Product boundary | Automated proof |
| --- | --- | --- |
| Same file from qBittorrent through Arr to Jellyfin | The private worker observation binds the exact torrent, import receipt, and Jellyfin item to three canonical mount views. All views must carry one device/inode identity, the download and library host paths must differ, and the Arr and Jellyfin library paths must resolve identically. The public response exposes only `hardlink_verified`, retry attempt, and bounded file count. | `test_hardlink_inode_and_canonical_mapping_prove_one_secret_free_file_chain`; rebound and journal-tamper matrix |
| Canonical container-to-host mapping | Absolute container root, item path, and host root are normalized lexically. Relative, traversal, sibling-prefix, doubled-separator, control-character, wrong-provider-order, and non-hardlink mappings fail before projection. The resolver never opens a supplied path. | `test_container_host_mapping_rejects_noncanonical_or_escaping_paths`; `test_container_host_mapping_resolves_only_the_relative_canonical_suffix` |
| Idempotent interruption and retry | One HMAC-protected request lineage retains the operation and request receipt. Each media item retains its torrent, import, playback, inode, and canonical-path digest. A later retry may increase its bounded attempt and add newly verified files, but it cannot remove or rebind accepted evidence. Duplicate seasons/files/receipts are rejected; uncertain effects do not advance either journal or the flow high-water mark. | `test_interrupted_retry_is_idempotent_and_uncertain_effect_fails_closed`; rebound/duplicate/tamper tests |

The contracts remain bound to the existing exact installation, source
revision, stable double-read, HMAC high-water, private worker, and current admin
session checks. Private paths, inode values, provider receipt identifiers, and
worker errors are not returned by the Core API.

Real qBittorrent, Sonarr/Radarr, and Jellyfin collectors must populate this
private evidence from the native S07.1 stack. This test slice does not claim a
live CasaOS/Proxmox filesystem, provider account, or physical playback result.
