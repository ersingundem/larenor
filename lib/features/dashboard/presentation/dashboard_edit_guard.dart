import 'package:flutter/cupertino.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
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
  AppInteractionController? _interaction;
  int? _interactionEpoch;
  bool _hasInteractionScope = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = AppInteractionScope.maybeOf(context);
    if (!identical(next, _interaction)) {
      _interaction?.removeListener(_interactionChanged);
      if (_hasInteractionScope) _expireInteraction();
      _interaction = next;
      _interactionEpoch = next?.epoch;
      next?.addListener(_interactionChanged);
    }
    _hasInteractionScope = true;
  }

  void _interactionChanged() {
    if (!mounted) return;
    final nextEpoch = _interaction?.epoch;
    if (nextEpoch == _interactionEpoch) return;
    _interactionEpoch = nextEpoch;
    _expireInteraction();
  }

  void _expireInteraction() {
    // Expire synchronously even when idle and wake happen before a frame.
    interactionGeneration++;
    void invalidate() {
      if (mounted) setState(invalidateDashboardInteraction);
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => invalidate());
    } else {
      invalidate();
    }
  }

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

  /// A popped page returns its value before Flutter restores the parent's
  /// ticker visibility. Wait for its transition before validating a local save.
  Future<R?> pushDashboardPage<R>(CupertinoPageRoute<R> route) async {
    final result = await Navigator.of(context).push<R>(route);
    await route.completed;
    return result;
  }

  bool interactionCurrent(int generation) =>
      mounted &&
      foreground &&
      interactionGeneration == generation &&
      identical(_interaction, AppInteractionScope.maybeRead(context)) &&
      _interaction?.active != false &&
      _interaction?.epoch == _interactionEpoch &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent != false;

  VoidCallback dashboardAction(VoidCallback action) {
    final generation = interactionGeneration;
    return () {
      if (interactionCurrent(generation)) action();
    };
  }

  @override
  void dispose() {
    interactionGeneration++;
    _interaction?.removeListener(_interactionChanged);
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
