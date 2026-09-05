import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/server_account_controller.dart';
import '../data/server_session_store.dart';

final serverSessionStoreProvider = Provider<ServerSessionPersistence>(
  (ref) => SecureServerSessionStore(),
);

final serverAccountControllerProvider = Provider<ServerAccountController>((
  ref,
) {
  final controller = ServerAccountController(
    store: ref.watch(serverSessionStoreProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
});
