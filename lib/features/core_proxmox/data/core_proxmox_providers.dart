import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/home_session_controller.dart';
import '../../home_resources/domain/home_resource_models.dart';
import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../core_ha/data/core_ha_providers.dart';
import 'core_proxmox_controller.dart';

final coreProxmoxApiFactoryProvider = Provider<ServerApiFactory>(
  (_) =>
      (endpoint) => LarenorServerApi(endpoint: endpoint),
);
final coreProxmoxClockProvider = Provider<DateTime Function()>(
  (_) => DateTime.now,
);
final coreProxmoxMonotonicProvider = Provider<Duration Function()>((_) {
  final watch = Stopwatch()..start();
  return () => watch.elapsed;
});
final coreProxmoxRequestIdProvider = Provider<String Function()>((_) {
  final random = Random.secure();
  return () => List<int>.generate(
    16,
    (_) => random.nextInt(256),
  ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
});

typedef CoreProxmoxSelection = ({
  CoreHaOwner owner,
  HomeResourceRecord target,
  bool admin,
});

final coreProxmoxControllerProvider = Provider.autoDispose
    .family<CoreProxmoxController, CoreProxmoxSelection>((ref, selection) {
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

      final controller = CoreProxmoxController(
        home,
        selection.target,
        ref.watch(coreProxmoxApiFactoryProvider),
        ref.watch(coreProxmoxClockProvider),
        ref.watch(coreProxmoxMonotonicProvider),
        current,
        selection.owner,
        admin: selection.admin,
      );
      ref.onDispose(() {
        controller.dispose();
        selection.owner.retire();
      });
      return controller;
    });
