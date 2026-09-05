import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/data/ha_connection_config.dart';
import '../../auth/providers/auth_providers.dart';
import '../../health/data/health_configuration.dart';
import '../../health/data/integration_health.dart';
import '../../media/hub/presentation/media_session_state.dart';

/// Source identity follows the configuration scope, not the lifetime of a
/// lazily built parent row. It contains no serialized credentials or UI keys.
bool Function()? captureHaRouteSource(BuildContext context) {
  if (!context.mounted) return null;
  final container = ProviderScope.containerOf(context, listen: false);
  final current = container.read(connectionConfigProvider);
  if (current.isLoading || current.hasError || current.value == null) {
    return null;
  }
  final config = current.value!;
  return () {
    try {
      final latest = container.read(connectionConfigProvider);
      return !latest.isLoading &&
          !latest.hasError &&
          sameHealthConfiguration(config, latest.value);
    } on StateError {
      return false;
    }
  };
}

class HaSessionLease {
  const HaSessionLease(this.generation, this.config);
  final int generation;
  final HaConnectionConfig config;
}

/// Guards a visible HA operation while preserving read-only source identity
/// across navigation. Pending confirmations expire on every background/hide.
abstract class HaSessionState<T extends ConsumerStatefulWidget>
    extends MediaSessionState<T> {
  bool _visible = true;
  bool sourceSessionCurrent() => true;
  bool get ownsRouteCover => false;
  bool get haSessionAvailable {
    if (!mounted ||
        !foreground ||
        !interactionActive ||
        !_visible ||
        sessionExpired ||
        !sourceSessionCurrent()) {
      return false;
    }
    final current = ref.read(connectionConfigProvider);
    return !current.isLoading && !current.hasError && current.value != null;
  }

  void watchHaSession() =>
      watchMediaAccount(IntegrationId.ha, connectionConfigProvider);
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Opaque child pages intentionally cover their source route. Their own
    // session guard protects actions; covering a route must not pop the child.
    final visible =
        TickerMode.valuesOf(context).enabled ||
        (ownsRouteCover && ModalRoute.of(context)?.isCurrent == false);
    if (_visible && !visible) {
      sessionGeneration++;
      clearPendingInteraction();
    }
    _visible = visible;
  }

  HaSessionLease? captureHaSession({bool requireCurrentRoute = true}) {
    if (!haSessionAvailable ||
        (requireCurrentRoute && ModalRoute.of(context)?.isCurrent != true)) {
      return null;
    }
    return HaSessionLease(
      sessionGeneration,
      ref.read(connectionConfigProvider).value!,
    );
  }

  bool isHaSessionCurrent(
    HaSessionLease lease, {
    bool requireCurrentRoute = true,
  }) =>
      haSessionAvailable &&
      sessionCurrent(lease.generation) &&
      (!requireCurrentRoute || ModalRoute.of(context)?.isCurrent == true) &&
      sameHealthConfiguration(
        lease.config,
        ref.read(connectionConfigProvider).value,
      );
  VoidCallback? haCallback(VoidCallback callback) {
    final lease = captureHaSession();
    return lease == null
        ? null
        : () {
            if (isHaSessionCurrent(lease)) callback();
          };
  }
}
