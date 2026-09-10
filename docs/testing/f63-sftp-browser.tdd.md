# F63 SFTP browser TDD evidence

Date: 10 September 2026

## Scope and journeys

This slice starts from the SSH terminal foundation already included in the
PR64 head. It keeps F63 open while adding one cohesive client capability:

- A tablet user can open an SFTP browser from any saved SSH profile without
  installing Larenor Core.
- The browser reuses the encrypted on-device SSH credential and pinned server
  key, but performs no connection or directory read before an explicit action.
- The user can read a normalized directory listing, download one file to an
  Android-selected destination, or select one Android document to upload.
- Cancel, navigation away, focus loss, owner retirement, or profile replacement
  closes the connection and prevents late work from publishing or replaying.

## Contract and limits

- One engine instance makes one SSH/SFTP connection attempt. There is no
  automatic reconnect, retry, command execution, or transfer replay.
- A listing retains at most 200 regular files/directories. Control characters,
  backslashes, unsafe filenames, and paths over 4096 UTF-8 bytes are rejected.
- A transfer is limited to 64 MiB. Android's document picker owns local reads
  and destinations. Upload creates a new remote file with exclusive mode and
  never overwrites an existing path.
- Download and upload buffers are overwritten after the explicit operation
  finishes or fails. Closing the owner also closes SFTP, SSH, and socket state.

## RED and GREEN evidence

| Guarantee | Test target | Type | Result |
| --- | --- | --- | --- |
| Path normalization and filename bounds | `sftp_models_test.dart` | Unit | PASS |
| Exact-length Android input and cancelled picker/save | `sftp_file_access_test.dart` | Unit | PASS |
| Pin/credential reuse, bounded listing, explicit transfers and cancellation | `sftp_controller_test.dart` | Unit/integration seam | PASS |
| 600/1280 tablet UI, entry point, explicit actions and focus cleanup | `sftp_browser_panel_test.dart` | Widget/integration | PASS |

RED checkpoints:

- `35627af`: missing SFTP model, file, transport, and controller contracts.
- `8d2d94e`: missing tablet browser panel and providers.

GREEN commands:

```text
flutter test --coverage test/features/remote_access/ssh/sftp_models_test.dart test/features/remote_access/ssh/sftp_file_access_test.dart test/features/remote_access/ssh/sftp_controller_test.dart test/features/remote_access/ssh/sftp_browser_panel_test.dart
16 tests passed.

flutter test test/features/remote_access
114 tests passed before the final profile-entry integration case was added.

flutter analyze lib/features/remote_access/ssh lib/features/remote_access/presentation/remote_profiles_screen.dart test/features/remote_access/ssh/sftp_models_test.dart test/features/remote_access/ssh/sftp_file_access_test.dart test/features/remote_access/ssh/sftp_controller_test.dart test/features/remote_access/ssh/sftp_browser_panel_test.dart
No issues found.
```

The controller and path policy have 219/249 covered lines (88.0%). Platform
picker branches and the real encrypted SSH/SFTP handshake are isolated behind
tested seams; their remaining acceptance requires an Android document provider
and a real, non-production SFTP fixture.

## Remaining F63 work

Full terminal emulation, SSH tunnels, remote rename/delete/mkdir operations,
large streaming transfers beyond the bounded Android document flow, and
physical-device SFTP acceptance remain separate later slices. Queue progress
therefore stays at 14/125 (11.2%) and selected-feature acceptance stays at
0/63 (0.0%).
