import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../server/providers/server_providers.dart';
import 'core_audit_checkpoint_store.dart';
import 'core_audit_controller.dart';

final coreAuditCheckpointStoreProvider = Provider<CoreAuditCheckpointStore>(
  (_) => CoreAuditCheckpointStore(),
);

final coreAuditControllerProvider = Provider.autoDispose<CoreAuditController>((
  ref,
) {
  final controller = CoreAuditController(
    ref.watch(serverAccountControllerProvider),
    ref.watch(coreAuditCheckpointStoreProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
});
