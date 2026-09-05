import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/providers/auth_providers.dart';
import '../../dashboard/providers/dashboard_live_providers.dart';
import '../../ha_client/data/ws_client.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../data/energy_api.dart';
import '../data/energy_controller.dart';
import '../data/energy_repository.dart';
import '../domain/energy_models.dart';
import '../domain/maintenance_models.dart';

final energyApiProvider = Provider.autoDispose<EnergyApi?>((ref) {
  final connection = ref.watch(connectionConfigProvider);
  if (connection.isLoading || connection.hasError || connection.value == null) {
    return null;
  }
  final rest = ref.watch(haRestClientProvider);
  final ws = ref.watch(haWebSocketClientProvider);
  return rest == null || ws == null ? null : HaEnergyApi(rest: rest, ws: ws);
});
final energyClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);
final energyControllerProvider = Provider.autoDispose<EnergyController?>((ref) {
  final connection = ref.watch(connectionConfigProvider);
  if (connection.isLoading || connection.hasError || connection.value == null) {
    return null;
  }
  final api = ref.watch(energyApiProvider);
  if (api == null) return null;
  final controller = EnergyController(
    repository: EnergyRepository(api: api, now: ref.watch(energyClockProvider)),
  );
  final state = WidgetsBinding.instance.lifecycleState;
  controller.setForeground(state == null || state == AppLifecycleState.resumed);
  final lifecycle = AppLifecycleListener(
    onStateChange: (state) =>
        controller.setForeground(state == AppLifecycleState.resumed),
  );
  ref.listen(haConnectionStatusProvider, (previous, next) {
    if (previous?.value != HaConnectionStatus.connected &&
        next.value == HaConnectionStatus.connected) {
      controller.refresh();
    }
  });
  ref.onDispose(() {
    lifecycle.dispose();
    controller.dispose();
  });
  return controller;
});
final energyProvider = StreamProvider.autoDispose<EnergyViewState>(
  (ref) =>
      ref.watch(energyControllerProvider)?.changes ??
      Stream.value(const EnergyViewState(connectionConfigured: false)),
);

final maintenanceProvider = Provider.autoDispose
    .family<MaintenanceSnapshot, MaintenanceScope>((ref, scope) {
      final entities = ref.watch(entitiesProvider);
      if (entities.isLoading || entities.hasError || entities.value == null) {
        return MaintenanceSnapshot(
          scope: scope,
          isLoading: entities.isLoading,
          readFailed: entities.hasError,
        );
      }
      final selected = scope == MaintenanceScope.selected
          ? ref.watch(dashboardVisibleIdsProvider)
          : const <String>{};
      return buildMaintenanceSnapshot(
        entities.value!,
        scope: scope,
        selectedIds: selected,
      );
    });
