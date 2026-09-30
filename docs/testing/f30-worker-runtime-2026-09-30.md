# F30 normal worker composition

The `larenor-media-archive-worker --config <private-runtime.json>` entry point
composes the real collector, sealed source resolver, Unmanic HTTP transport,
durable callback receiver, protected files, FFmpeg verifier and action journal.
`larenor-unmanic-callback-package --output <new-plugin.zip>` produces a
reproducible standalone plugin package; it refuses to overwrite an existing
artifact. Metadata and root ZIP layout follow the
[official plugin contract](https://docs.unmanic.app/docs/development/writing_plugins/introduction/)
and [0.4.1 installer](https://github.com/Unmanic/unmanic/blob/1c324b8fc3974ffce3d7cc945adb938fe7182910/unmanic/libs/plugins.py).

Provisioning requires owned 0700 directories and 0600 JSON/key files. The worker,
Unmanic and callback listener share an isolated loopback network namespace and
the same absolute work-root mount. Unmanic receives only the staged work copy;
the approved original library and retained-original roots are separate. An
actual encoder plugin must be configured in the isolated Unmanic library, and
the callback plugin must be enabled for `emit_postprocessor_complete`.

The resolver catalog's exact fields are `schemaVersion: 1`, `storeRoot`,
`workRoot`, `retainedRoot`, `authenticationKeyFile` and `approvedMounts`.
Each approved mount contains `mountId`, `jellyfinRoot` and `hostRoot`. The key
file contains 32 random bytes. The catalog contains no Unmanic library ID;
the worker reads and binds the actual library ID and full configuration digest
through GET libraries and POST library/read on every collection/resolution.

The runtime JSON's exact fields are `schemaVersion: 1`, `resolverCatalog`,
`readSocket`, `actionSocket`, `authoritySocket`, `coreUid`, `unmanicPort`,
`callbackPort`, `journalRoot`, `terminalRoot`, `callbackKeyFile`, `ffmpeg`,
`ffprobe` and `quotaBytes`. Paths are absolute; sockets are at most 103 UTF-8
bytes. Roots must be distinct and non-nested. The quota is 256 MiB–10 TiB.
The callback key is a separate 32-byte secret shared with the plugin.

The plugin's exact private configuration fields are `schemaVersion: 1`,
`outboxDirectory`, `workRoot`, `keyFile` and `callbackPort`.
Set `LARENOR_UNMANIC_CALLBACK_CONFIG` before Unmanic starts so persisted outbox
rows retry after restart without waiting for another completion event.

Core uses `LARENOR_MEDIA_ARCHIVE_WORKER_SOCKET`,
`LARENOR_MEDIA_ARCHIVE_ACTION_WORKER_SOCKET`,
`LARENOR_MEDIA_ARCHIVE_AUTHORITY_SOCKET` and the corresponding worker UID
settings. Both processes share the trusted OS UID domain because Unix sockets
are 0600; the callback route is loopback-only. The worker obtains live authority
from Core's authority-only socket. A sealed cached source record does not grant
authority after logout, service/binding drift or snapshot changes.

The OS peer UID is read from kernel credentials. Linux uses SO_PEERCRED;
Darwin uses the version and effective-UID prefix of
[xucred / LOCAL_PEERCRED](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/ucred.h).
Shutdown removes only a socket inode created by the current worker. Failed
startup leaves existing files/sockets belonging to another process intact.

Validation: 41 focused runtime, actual Unix IPC, callback delivery, action
contract and package tests passed. Resolver/collector/Core authority bridge and
related archive regression passed 107 tests. These use local temporary media,
real FFmpeg and bounded HTTP protocol fixtures. Pinned Unmanic process/plugin
installation and complete Client→Core→worker deployment acceptance remain
separate gates; these counts do not close F30 or any final item.
