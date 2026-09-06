import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/home_session_controller.dart';
import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../domain/home_person_models.dart';
import 'home_people_controller.dart';
import 'home_person_grants_controller.dart';

/// One mounted page owns one handle. The screen must synchronize on route,
/// native focus, PIN or container changes and dispose this handle on exit.
/// A return to that page uses a new handle; an old confirmation never revives.
class HomePeopleOwner extends ChangeNotifier {
  HomePeopleOwner({
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
      if (_interaction.active && _interaction.epoch == _epoch && _current())
        return true;
    } catch (_) {
      /* A failing owner check confers no permission. */
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

final homePeopleApiFactoryProvider = Provider<ServerApiFactory>(
  (_) =>
      (endpoint) => LarenorServerApi(endpoint: endpoint),
);
final homePeopleClockProvider = Provider<DateTime Function()>(
  (_) => DateTime.now,
);

bool Function() _bind(
  Ref ref,
  HomePeopleOwner owner,
  HomeSessionController? home,
) {
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

typedef HomePeopleSelection = ({
  HomePeopleOwner owner,
  bool adminManagement,
  int pageSize,
});
final homePeopleControllerProvider = Provider.autoDispose
    .family<HomePeopleController, HomePeopleSelection>((ref, selection) {
      final home = ref.watch(homeSessionControllerProvider);
      final controller = HomePeopleController(
        home,
        ref.watch(homePeopleApiFactoryProvider),
        ref.watch(homePeopleClockProvider),
        _bind(ref, selection.owner, home),
        selection.owner,
        adminManagement: selection.adminManagement,
        pageSize: selection.pageSize,
      );
      ref.onDispose(() {
        controller.dispose();
        selection.owner.retire();
      });
      return controller;
    });
typedef HomePersonGrantSelection = ({
  HomePeopleOwner owner,
  HomePersonRecord target,
});
final homePersonGrantsControllerProvider = Provider.autoDispose
    .family<HomePersonGrantsController, HomePersonGrantSelection>((
      ref,
      selection,
    ) {
      final home = ref.watch(homeSessionControllerProvider);
      final controller = HomePersonGrantsController(
        home,
        selection.target,
        ref.watch(homePeopleApiFactoryProvider),
        ref.watch(homePeopleClockProvider),
        _bind(ref, selection.owner, home),
        selection.owner,
      );
      ref.onDispose(() {
        controller.dispose();
        selection.owner.retire();
      });
      return controller;
    });
