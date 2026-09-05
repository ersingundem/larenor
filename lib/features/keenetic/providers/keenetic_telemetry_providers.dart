import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/keenetic_telemetry.dart';
import 'keenetic_providers.dart';
import 'keenetic_telemetry_controller.dart';

export '../data/keenetic_telemetry.dart';

final keeneticTelemetryControllerProvider =
    Provider.autoDispose<KeeneticTelemetryController>((ref) {
      final connection = ref.watch(keeneticConnectionProvider);
      final config = connection.isLoading || connection.hasError
          ? null
          : connection.value;
      final health = ref.watch(keeneticHealthSessionProvider);
      final client = config == null
          ? null
          : ref.watch(keeneticClientFactoryProvider)(config, health);
      final controller = KeeneticTelemetryController(
        client: client,
        initialIssue: connection.hasError
            ? KeeneticReadFailure.invalidResponse
            : null,
      );
      ref.onDispose(controller.dispose);
      return controller;
    });

/// Watch only for visible operational cards/screens, never layout previews.
final keeneticMetricProvider = StreamProvider.autoDispose
    .family<KeeneticTelemetrySnapshot, KeeneticMetricRequest>((ref, request) {
      final controller = ref.watch(keeneticTelemetryControllerProvider);
      ref.onDispose(controller.register(request));
      return controller.changes;
    });
