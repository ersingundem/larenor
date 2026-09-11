import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/health_monitor.dart';
import '../data/integration_health.dart';

final healthMonitorProvider = Provider<HealthMonitor>((ref) {
  final monitor = HealthMonitor();
  ref.onDispose(monitor.dispose);
  return monitor;
});

final integrationHealthProvider = StreamProvider.autoDispose
    .family<IntegrationHealth, IntegrationId>((ref, id) {
      return ref
          .watch(healthMonitorProvider)
          .changes
          .map((snapshot) => snapshot[id] ?? const IntegrationHealth())
          .distinct();
    });

/// UI freshness must age even if neither server nor entity sends a new value.
/// The timer only lives while a health-status consumer is mounted.
final healthClockProvider = StreamProvider.autoDispose<DateTime>((ref) {
  final values = StreamController<DateTime>();
  Timer? timer;
  void schedule(AppLifecycleState? state) {
    timer?.cancel();
    timer = null;
    if (state == null || state == AppLifecycleState.resumed) {
      timer = Timer.periodic(
        const Duration(seconds: 15),
        (_) => values.add(DateTime.now()),
      );
    }
  }

  void update(AppLifecycleState? state) {
    if (state == null || state == AppLifecycleState.resumed) {
      values.add(DateTime.now());
    }
    schedule(state);
  }

  final lifecycle = AppLifecycleListener(onStateChange: update);
  update(WidgetsBinding.instance.lifecycleState);
  ref.onCancel(() {
    timer?.cancel();
    timer = null;
  });
  ref.onResume(() => schedule(WidgetsBinding.instance.lifecycleState));
  ref.onDispose(() {
    timer?.cancel();
    lifecycle.dispose();
    unawaited(values.close());
  });
  return values.stream;
});

final integrationHealthStatusProvider = Provider.autoDispose
    .family<HealthStatus, IntegrationId>((ref, id) {
      final health =
          ref.watch(integrationHealthProvider(id)).value ??
          ref.read(healthMonitorProvider).read(id);
      final now = ref.watch(healthClockProvider).value ?? DateTime.now();
      return health.statusAt(now);
    });
