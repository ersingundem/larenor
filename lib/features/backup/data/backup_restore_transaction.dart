part of 'backup_repository.dart';

/// Plaintext stays private and never appears in diagnostics or serialization.
final class PreparedBackupRestore {
  PreparedBackupRestore._();
  void retire() {}
  void claimForHandoff(Object owner) => throw const BackupException('restore_unavailable', 'Restore is unavailable.');
  Future<void> applyAfterHandoff(Object owner, {required bool Function() isCurrentBoundary}) async => throw const BackupException('restore_unavailable', 'Restore is unavailable.');
}
