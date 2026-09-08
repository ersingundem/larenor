import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/app_interaction_scope.dart';
import '../../../core/home_session_controller.dart';
import '../../auth/providers/auth_providers.dart';
import '../../dashboard/providers/dashboard_providers.dart';
import '../data/core_ha_providers.dart';
import 'transfer_controller.dart';

/// A transfer route has a distinct, sticky owner. It cannot be shared by routes.
class CoreHaTransferOwner extends ChangeNotifier {
  CoreHaTransferOwner({required bool Function() isCurrent, required AppInteractionController interaction})
      : _current = isCurrent, _interaction = interaction, _epoch = interaction.epoch {
    interaction.addListener(synchronize);
  }
  final bool Function() _current;
  final AppInteractionController _interaction;
  final int _epoch;
  bool _retired = false, _disposed = false;
  Object? _binding;
  bool get isCurrent {
    if (_retired || _disposed) return false;
    try { if (_interaction.active && _interaction.epoch == _epoch && _current()) return true; }
    catch (_) { /* No authority. */ }
    retire(); return false;
  }
  void _bind(Object ref) {
    if (_binding != null && !identical(_binding, ref)) retire();
    _binding ??= ref;
  }
  void synchronize() { if (!_disposed) { final _ = isCurrent; } }
  void retire() { if (_retired || _disposed) return; _retired = true; notifyListeners(); }
  @override void dispose() {
    retire(); _disposed = true; _interaction.removeListener(synchronize); super.dispose();
  }
}
final coreHaTransferControllerProvider = Provider.autoDispose.family<CoreHaTransferController, CoreHaTransferOwner>((ref, owner) {
  owner._bind(ref);
  final home = ref.watch(homeSessionControllerProvider),
      repository = ref.watch(dashboardRepositoryProvider),
      credentials = ref.watch(credentialsStoreProvider);
  final identity = home?.runtimeIdentity, epoch = home?.interaction.epoch, generation = home?.account.generation;
  bool current() => ref.mounted && identical(ref.read(homeSessionControllerProvider), home) &&
      identical(ref.read(dashboardRepositoryProvider), repository) && identical(ref.read(credentialsStoreProvider), credentials) &&
      home?.runtimeIdentity == identity && home?.interaction.epoch == epoch && home?.account.generation == generation && owner.isCurrent;
  final controller = CoreHaTransferController(home: home, repository: repository, credentials: credentials,
      factory: ref.watch(coreHaApiFactoryProvider), clock: ref.watch(coreHaClockProvider),
      monotonic: ref.watch(coreHaMonotonicProvider), requestId: ref.watch(coreHaRequestIdProvider), current: current, owner: owner);
  ref.onDispose(() { controller.dispose(); owner.retire(); });
  return controller;
});
