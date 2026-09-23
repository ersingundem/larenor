# F63 SFTP buffer integrity TDD evidence

Date: 23 September 2026

## Scope

This slice hardens the existing Android document-provider boundary without
changing the user-visible SFTP workflow:

- SFTP paths and filenames reject unpaired UTF-16 surrogates instead of
  silently converting them to replacement characters.
- Download exports use a private buffer that is overwritten after success,
  cancellation, or provider failure; the caller's source buffer is unchanged.
- Upload collection uses one exact-sized owned buffer, rejects length drift and
  provider errors, and overwrites partial bytes before returning a failure.

`SftpUpload.adoptOwned` transfers an already-private allocation into the upload
object. The controller remains responsible for calling `clear()` when the
transfer completes or the owning session retires.

## RED and GREEN evidence

RED commit `0c5c6da9` failed four focused cases: malformed UTF-16 was accepted,
download export buffers remained populated after both outcomes, and stream
errors leaked their provider exception.

GREEN commit `a743fd55` passes the focused model and file-access suite:

```text
flutter test test/features/remote_access/ssh/sftp_models_test.dart \
  test/features/remote_access/ssh/sftp_file_access_test.dart
10 tests passed.

flutter analyze lib/features/remote_access/ssh/sftp_models.dart \
  lib/features/remote_access/ssh/sftp_file_access.dart \
  test/features/remote_access/ssh/sftp_models_test.dart \
  test/features/remote_access/ssh/sftp_file_access_test.dart
No issues found.
```

F63 remains open for physical Android document-provider acceptance and real
SFTP interoperability. This slice does not advance the 125-item acceptance
counter by itself.
