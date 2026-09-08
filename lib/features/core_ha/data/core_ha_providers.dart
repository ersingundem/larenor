import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/home_session_controller.dart';
import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../home_resources/domain/home_resource_models.dart';
import 'core_ha_controller.dart';

/// One mounted page owns one handle. The screen must synchronize on route,
/// native focus, PIN or container changes and dispose this handle on exit.
/// A return to that page uses a new handle; an old confirmation never revives.
class CoreHaOwner extends ChangeNotifier {
  CoreHaOwner({
    required bool Function() isCurrent,
    required AppInteractionController interaction,
  }) : _current = isCurrent,
       _interaction = interaction,
       _epoch = interaction.epoch {
    interaction.addListener(synchronize);
  }
  final bool Function() _current;
  final AppInteractionController _interaction;
  final int _epoch;
  bool _retired = false, _disposed = false;
  Object? _binding;
  bool get isCurrent {
    if (_retired || _disposed) return false;
    try {
      if (_interaction.active && _interaction.epoch == _epoch && _current()) {
        return true;
      }
    } catch (_) {
      // A failing owner check confers no permission.
    }
    retire();
    return false;
  }

  void _bind(Object binding) {
    if (_binding != null && !identical(_binding, binding)) retire();
    _binding ??= binding;
  }

  void synchronize() {
    if (!_disposed) {
      final _ = isCurrent;
    }
  }

  void retire() {
    if (_retired || _disposed) return;
    _retired = true;
    notifyListeners();
  }

  @override
  void dispose() {
    retire();
    _disposed = true;
    _interaction.removeListener(synchronize);
    super.dispose();
  }
}

final coreHaApiFactoryProvider = Provider<ServerApiFactory>(
  (_) =>
      (endpoint) => LarenorServerApi(endpoint: endpoint),
);
final coreHaClockProvider = Provider<DateTime Function()>((_) => DateTime.now);

bool Function() _bind(Ref ref, CoreHaOwner owner, HomeSessionController? home) {
  owner._bind(ref);
  final identity = home?.runtimeIdentity,
      epoch = home?.interaction.epoch,
      generation = home?.account.generation;
  return () {
    if (!ref.mounted ||
        !identical(ref.read(homeSessionControllerProvider), home) ||
        home?.runtimeIdentity != identity ||
        home?.interaction.epoch != epoch ||
        home?.account.generation != generation) {
      owner.retire();
      return false;
    }
    return owner.isCurrent;
  };
}

final coreHaMonotonicProvider = Provider<Duration Function()>((_) {
  final watch = Stopwatch()..start();
  return () => watch.elapsed;
});
typedef CoreHaSelection = ({
  CoreHaOwner owner,
  HomeResourceRecord target,
  bool admin,
});
final coreHaControllerProvider = Provider.autoDispose
    .family<CoreHaController, CoreHaSelection>((ref, selection) {
      final home = ref.watch(homeSessionControllerProvider);
      final controller = CoreHaController(
        home,
        selection.target,
        ref.watch(coreHaApiFactoryProvider),
        ref.watch(coreHaClockProvider),
        ref.watch(coreHaMonotonicProvider),
        _bind(ref, selection.owner, home),
        selection.owner,
        admin: selection.admin,
      );
      ref.onDispose(() {
        controller.dispose();
        selection.owner.retire();
      });
      return controller;
    });
