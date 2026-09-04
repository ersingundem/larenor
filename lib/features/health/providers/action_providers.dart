import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/action_controller.dart';
import '../data/action_receipt.dart';
import 'health_providers.dart';

final actionControllerProvider = Provider<ActionController>((ref) {
  final controller = ActionController();
  final changes = ref
      .watch(healthMonitorProvider)
      .configurationChanges
      .listen(controller.resetIntegration);
  ref.onDispose(() => unawaited(changes.cancel()));
  ref.onDispose(controller.dispose);
  return controller;
});

final actionReceiptsProvider = StreamProvider<List<ActionReceipt>>(
  (ref) => ref.watch(actionControllerProvider).changes,
);
