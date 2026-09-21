# S09.3 restore container acceptance foundation

Date: 2026-09-21

The existing Server image matrix now runs the same encrypted backup and empty
restore acceptance on `linux/amd64` and `linux/arm64`. The image runs as UID
10001 with no network, a read-only root filesystem, dropped capabilities,
bounded CPU/memory/PIDs and only one private writable acceptance mount.

The script initializes a source Core, changes the bootstrap password, stores an
encrypted Home Assistant connection fixture, creates an encrypted bundle,
restores it into a second empty Core, then proves the identity, vault key,
connection document and login survive another restart. It also proves plaintext
credentials are absent from both output and the encrypted bundle.

The script has a local Server test so protocol and import regressions fail
before the image matrix. S09.3 remains pending until S09.1/S09.2 and B2 land,
the exact dual-architecture workflow passes, and independent review closes the
queue task.
