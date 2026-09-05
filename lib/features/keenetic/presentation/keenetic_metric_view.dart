import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/keenetic_providers.dart';
import '../providers/keenetic_telemetry_providers.dart';

/// Offstage routes and background windows release their metric demand. The
/// shared controller aggregates the remaining visible consumers.
class KeeneticMetricView extends ConsumerStatefulWidget {
  const KeeneticMetricView({
    super.key,
    required this.request,
    required this.builder,
  });
  final KeeneticMetricRequest request;
  final Widget Function(
    BuildContext,
    AsyncValue<KeeneticTelemetrySnapshot?>,
    bool configured,
  )
  builder;
  @override
  ConsumerState<KeeneticMetricView> createState() => _KeeneticMetricViewState();
}

class _KeeneticMetricViewState extends ConsumerState<KeeneticMetricView> {
  late final AppLifecycleListener _lifecycle;
  bool _foreground = true;
  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (mounted) {
          setState(() => _foreground = state == AppLifecycleState.resumed);
        }
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connection = ref.watch(keeneticConnectionProvider);
    final configured =
        !connection.isLoading &&
        !connection.hasError &&
        connection.value != null;
    final AsyncValue<KeeneticTelemetrySnapshot?> reading;
    if (!_foreground || !TickerMode.valuesOf(context).enabled) {
      reading = const AsyncData(null);
    } else if (connection.isLoading) {
      reading = const AsyncLoading();
    } else if (connection.hasError) {
      reading = AsyncError(
        connection.error!,
        connection.stackTrace ?? StackTrace.empty,
      );
    } else if (!configured) {
      reading = const AsyncData(null);
    } else {
      reading = ref.watch(keeneticMetricProvider(widget.request));
    }
    return widget.builder(context, reading, configured);
  }
}
