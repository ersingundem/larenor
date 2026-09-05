import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/client_update_api.dart';
import '../data/client_update_controller.dart';

final clientUpdateApiProvider = Provider<ClientUpdateApi>(
  (ref) => AndroidClientUpdateApi(),
);

/// The authenticated server provider supplies a stable source per login, then
/// disposes/invalidate it on logout. The UI owns visible/idle lifecycle guards.
final clientUpdateControllerProvider = Provider.autoDispose
    .family<ClientUpdateController, ClientUpdateSource>((ref, source) {
      final controller = ClientUpdateController(
        ref.watch(clientUpdateApiProvider),
        source,
      );
      ref.onDispose(controller.dispose);
      return controller;
    });
