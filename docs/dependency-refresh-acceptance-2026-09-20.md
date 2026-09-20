# Dependency refresh acceptance

This maintenance slice consolidates the five version updates that Dependabot
opened independently on 20 September 2026. It keeps the queue counters at
17/125 and selected-feature counters at 0/63 because it does not complete a
product acceptance node.

## Accepted changes

1. `docker/build-push-action`, `docker/setup-buildx-action` and
   `android-actions/setup-android` use the reviewed immutable revisions from
   their generated update pull requests. The edited workflows pass actionlint
   and the repository security policy.
2. `file_picker` 13.1.0 and `flutter_secure_storage` 11.2.0 resolve under the
   pinned Flutter 3.47.2 / Dart 3.13.2 toolchain. Missing provider lengths now
   fail closed before a file stream or upload starts across all seven affected
   Client boundaries.
3. Full Flutter analysis is clean. The focused secure-storage, layout archive,
   ambient, backup, bounded upload, local artwork, qBittorrent and SFTP suites
   pass with 196 tests in the two targeted runs.

The original bot pull requests are superseded by this trailer-bearing commit;
future version scans are handled by the separate grouped-update configuration.
