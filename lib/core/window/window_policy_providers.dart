import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'window_policy_bridge.dart';
import 'window_policy_models.dart';

final windowPolicyBridgeProvider = Provider<WindowPolicyBridge>(
  (ref) => WindowPolicyBridge(),
);

final windowPolicySnapshotProvider = StreamProvider<WindowPolicySnapshot>(
  (ref) => ref.watch(windowPolicyBridgeProvider).changes,
  retry: (_, _) => null,
);
