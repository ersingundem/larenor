import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/providers/auth_providers.dart';
import '../../health/data/health_configuration.dart';
import '../domain/dashboard_room.dart';
import '../domain/ha_area_binding.dart';

/// Guards local editors and already-visible accessory callbacks without
/// starting a Home Assistant connection merely to display a layout preview.
abstract class DashboardEditState<T extends ConsumerStatefulWidget>
    extends ConsumerState<T> {
  int interactionGeneration = 0;
  bool foreground = true;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    foreground = state == null || state == AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        final next = state == AppLifecycleState.resumed;
        if (foreground == next) return;
        setState(() {
          foreground = next;
          if (!next) {
            interactionGeneration++;
            invalidateDashboardInteraction();
          }
        });
      },
    );
  }

  void watchDashboardAccount() {
    if (!ref.exists(connectionConfigProvider)) return;
    ref.watch(connectionConfigProvider);
    ref.listen(connectionConfigProvider, (previous, next) {
      if (next.isLoading ||
          next.hasError ||
          !sameHealthConfiguration(previous?.value, next.value)) {
        setState(() {
          interactionGeneration++;
          invalidateDashboardInteraction();
        });
      }
    });
  }

  void invalidateDashboardInteraction() {}

  bool interactionCurrent(int generation) =>
      mounted && foreground && interactionGeneration == generation;

  VoidCallback dashboardAction(VoidCallback action) {
    final generation = interactionGeneration;
    return () {
      if (interactionCurrent(generation)) action();
    };
  }

  @override
  void dispose() {
    interactionGeneration++;
    _lifecycle.dispose();
    super.dispose();
  }
}

/// A bound room is source-specific, including members manually added to it.
/// Calling code should avoid creating its live controls when this is false.
bool roomMatchesCurrentServer(WidgetRef ref, DashboardRoom room) {
  final binding = room.areaBinding;
  if (binding == null) return true;
  final current = ref.read(connectionConfigProvider);
  if (current.isLoading || current.hasError || current.value == null) {
    return false;
  }
  try {
    return normalizedAreaServerUrl(current.value!.baseUrl) == binding.serverUrl;
  } catch (_) {
    return false;
  }
}

/// A stale modal callback must never pop the page underneath it.
void closeDashboardModal<T>(BuildContext context, [T? value]) {
  if (context.mounted && ModalRoute.of(context)?.isCurrent == true) {
    Navigator.pop(context, value);
  }
}
