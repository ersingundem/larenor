import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../home_resources/domain/home_resource_models.dart';
import 'proxmox_power_models.dart';

/// Exact command targets are deliberately unavailable until Core publishes a
/// revision-bound guest descriptor. A read-only summary is never promoted to
/// command authority by the Client.
final coreProxmoxPowerTargetProvider =
    Provider.family<ProxmoxPowerTarget?, HomeResourceRecord>((ref, target) {
      return null;
    });
