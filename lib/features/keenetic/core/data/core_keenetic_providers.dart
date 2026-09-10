import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/home_session_controller.dart';
import '../../../core_ha/data/core_ha_providers.dart';
import '../../../home_resources/domain/home_resource_models.dart';
import '../../../server/data/larenor_server_api.dart';
import '../../../server/data/server_account_controller.dart';
import 'core_keenetic_controller.dart';

final coreKeeneticApiFactoryProvider = Provider<ServerApiFactory>(
  (_) =>
      (endpoint) => LarenorServerApi(endpoint: endpoint),
);
final coreKeeneticClockProvider = Provider<DateTime Function()>(
  (_) => DateTime.now,
);
typedef CoreKeeneticSelection = ({
  CoreHaOwner owner,
  HomeResourceRecord target,
  bool admin,
});

final coreKeeneticControllerProvider = Provider.autoDispose
    .family<CoreKeeneticController, CoreKeeneticSelection>((ref, selection) {
      final home = ref.watch(homeSessionControllerProvider),
          identity = home?.runtimeIdentity,
          interactionEpoch = home?.interaction.epoch,
          accountGeneration = home?.account.generation;
      bool current() {
        if (!ref.mounted ||
            !identical(ref.read(homeSessionControllerProvider), home) ||
            home?.runtimeIdentity != identity ||
            home?.interaction.epoch != interactionEpoch ||
            home?.account.generation != accountGeneration) {
          selection.owner.retire();
          return false;
        }
        return selection.owner.isCurrent;
      }

      final controller = CoreKeeneticController(
        home,
        selection.target,
        ref.watch(coreKeeneticApiFactoryProvider),
        ref.watch(coreKeeneticClockProvider),
        current,
        selection.owner,
        admin: selection.admin,
      );
      ref.onDispose(controller.dispose);
      return controller;
    });
