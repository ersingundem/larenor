import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../server/data/server_session_store.dart';
import '../../settings/data/pin_lock_store.dart';
import 'backup_restore_access.dart';
import 'backup_snapshot.dart';

abstract final class CapturedRestoreAccess {
  static Future<BackupRestoreAccess> capture({
    required HomeSessionController? home,
    required HomeSourcePersistence sourceStore,
    required ServerSessionPersistence sessionStore,
    required PinLockStore pinStore,
    required String? expectedPin,
    required bool Function() isCurrent,
    DateTime Function()? clock,
  }) async => throw const BackupException('restore_expired','Read the restore preview again.');
}
