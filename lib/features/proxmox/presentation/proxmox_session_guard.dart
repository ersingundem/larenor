import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../health/data/health_configuration.dart';
import '../data/proxmox_client.dart';
import '../data/proxmox_config.dart';
import '../providers/proxmox_providers.dart';

/// Capture the account before constructing a route with account-specific IDs.
/// Unlike an action lease, this survives foreground changes and equal-value
/// configuration reloads. It never follows a new account into an old route.
bool Function()? captureProxmoxRouteSource(WidgetRef ref) {
  if (!ref.context.mounted) return null;
  final container = ProviderScope.containerOf(ref.context, listen: false);
  final value = ref.read(proxmoxConnectionProvider);
  final source = value.isLoading || value.hasError ? null : value.value;
  if (source == null) return null;
  return () {
    // The source row can legitimately unmount when its covered route releases
    // polling demand. Scope identity belongs to the container, not that row.
    try {
      final current = container.read(proxmoxConnectionProvider);
      return !current.isLoading &&
          !current.hasError &&
          sameHealthConfiguration(source, current.value);
    } on StateError {
      return false;
    }
  };
}

/// An in-memory operation scope, never a persisted credential or diagnostic.
class ProxmoxSessionLease {
  const ProxmoxSessionLease._(this.client, this.generation);
  final ProxmoxClient client;
  final int generation;
}

/// Keep route IDs, drafts and asynchronous callbacks attached to their source
/// account. This guard itself reads local configuration only, not the network.
abstract class ProxmoxSessionState<T extends ConsumerStatefulWidget>
    extends ConsumerState<T> {
  ProxmoxConfig? _source;
  bool _bound = false, _changed = false, _unresolved = true;
  bool foreground = true;
  int sessionGeneration = 0;
  late final AppLifecycleListener _lifecycle;

  bool get sessionExpired => _changed || _unresolved;

  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    foreground = state == null || state == AppLifecycleState.resumed;
    _observe(ref.read(proxmoxConnectionProvider));
    ref.listenManual(proxmoxConnectionProvider, (_, next) {
      if (!mounted) return;
      setState(() => _observe(next));
    });
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (!mounted) return;
        final active = state == AppLifecycleState.resumed;
        if (active == foreground) return;
        setState(() {
          foreground = active;
          if (!active) {
            sessionGeneration++;
            onSessionInvalidated();
          }
        });
        if (active) onSessionResumed();
      },
    );
  }

  void _observe(AsyncValue<ProxmoxConfig?> value) {
    final unresolved = value.isLoading || value.hasError;
    final changed =
        !unresolved && _bound && !sameHealthConfiguration(_source, value.value);
    if ((!_unresolved && unresolved) || (!_changed && changed)) {
      sessionGeneration++;
      _changed = _changed || changed;
      onSessionInvalidated();
    }
    _unresolved = unresolved;
    if (!_bound && !unresolved) {
      _source = value.value;
      _bound = true;
    }
  }

  /// Call directly in build. A loading/error value never exposes retained data.
  void watchProxmoxSession() => ref.watch(proxmoxConnectionProvider);

  bool get sessionAvailable {
    if (!mounted ||
        !foreground ||
        sessionExpired ||
        _source == null ||
        !sourceSessionCurrent()) {
      return false;
    }
    final current = ref.read(proxmoxConnectionProvider);
    return !current.isLoading &&
        !current.hasError &&
        sameHealthConfiguration(_source, current.value);
  }

  /// Invalidate dialogs, polling and sensitive drafts in subclasses. An already
  /// accepted server operation is not rolled back or automatically replayed.
  void onSessionInvalidated() {}
  void onSessionResumed() {}
  bool sourceSessionCurrent() => true;

  bool _routeCurrent() => ModalRoute.of(context)?.isCurrent != false;

  ProxmoxSessionLease? captureSession({bool requireCurrentRoute = true}) {
    if (!sessionAvailable || (requireCurrentRoute && !_routeCurrent())) {
      return null;
    }
    final value = ref.read(proxmoxClientProvider);
    final client = value.isLoading || value.hasError ? null : value.value;
    if (client == null || !sameHealthConfiguration(_source, client.config)) {
      return null;
    }
    return ProxmoxSessionLease._(client, sessionGeneration);
  }

  bool isSessionCurrent(
    ProxmoxSessionLease lease, {
    bool requireCurrentRoute = true,
  }) {
    if (!sessionAvailable ||
        lease.generation != sessionGeneration ||
        (requireCurrentRoute && !_routeCurrent())) {
      return false;
    }
    final current = ref.read(proxmoxClientProvider);
    return !current.isLoading &&
        !current.hasError &&
        identical(current.value, lease.client) &&
        sameHealthConfiguration(_source, lease.client.config);
  }

  /// Only for explicit/bounded reads. Mutations must capture the existing client
  /// before confirmation and must never await a replacement account's client.
  Future<ProxmoxSessionLease?> readSessionClient({
    bool requireCurrentRoute = true,
  }) async {
    if (!sessionAvailable || (requireCurrentRoute && !_routeCurrent())) {
      return null;
    }
    final generation = sessionGeneration;
    final client = await ref.read(proxmoxClientProvider.future);
    if (client == null) return null;
    final lease = ProxmoxSessionLease._(client, generation);
    return isSessionCurrent(lease, requireCurrentRoute: requireCurrentRoute)
        ? lease
        : null;
  }

  @override
  void dispose() {
    sessionGeneration++;
    _lifecycle.dispose();
    super.dispose();
  }
}
