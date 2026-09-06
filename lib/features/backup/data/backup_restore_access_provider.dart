import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../server/providers/server_providers.dart';
import '../../settings/providers/settings_providers.dart';
import 'backup_restore_access.dart';
import 'captured_restore_access.dart';

typedef BackupRestoreAccessFactory = Future<BackupRestoreAccess> Function({
  required String? expectedPin,
  required bool Function() isCurrent,
});
final backupRestoreAccessFactoryProvider = Provider<BackupRestoreAccessFactory>(
  (ref) => ({required expectedPin, required isCurrent}) {
    final home = ref.read(homeSessionControllerProvider);
    return CapturedRestoreAccess.capture(
      home: home,
      sourceStore: home?.store ?? SharedPreferencesHomeSourceStore(),
      sessionStore: ref.read(serverSessionStoreProvider),
      pinStore: ref.read(pinLockStoreProvider),
      expectedPin: expectedPin,
      isCurrent: () =>
          ref.mounted &&
          identical(ref.read(homeSessionControllerProvider), home) &&
          isCurrent(),
    );
  },
);
