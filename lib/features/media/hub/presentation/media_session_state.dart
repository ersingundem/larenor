import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';

import '../../../../core/app_interaction_scope.dart';
import '../../../health/data/integration_health.dart';
import '../../../health/data/health_configuration.dart';
import '../../arr/providers/radarr_providers.dart';
import '../../arr/providers/sonarr_providers.dart';
import '../../bazarr/providers/bazarr_providers.dart';
import '../../jellyfin/providers/jellyfin_providers.dart';
import '../../jellyseerr/providers/jellyseerr_providers.dart';

/// A route may contain IDs, images and drafts from a particular media account.
/// A different account must resolve the route again before those can be reused.
abstract class MediaSessionState<T extends ConsumerStatefulWidget>
    extends ConsumerState<T> {
  final _accounts = <IntegrationId, Object?>{};
  final _unresolvedAccounts = <IntegrationId>{};
  bool _accountChanged = false;
  late final AppLifecycleListener _lifecycle;
  bool sessionExpired = false;
  bool foreground = true;
  int sessionGeneration = 0;
  AppInteractionController? _interaction;
  int _interactionEpoch = 0;
  bool get interactionActive => _interaction?.active ?? true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = AppInteractionScope.maybeOf(context);
    if (identical(next, _interaction)) return;
    final hadScope = _interaction != null;
    _interaction?.removeListener(_interactionChanged);
    _interaction = next;
    _interactionEpoch = next?.epoch ?? 0;
    next?.addListener(_interactionChanged);
    if (hadScope || !interactionActive) {
      sessionGeneration++;
      clearPendingInteraction();
    }
  }

  void _interactionChanged() {
    if (!mounted) return;
    final epoch = _interaction?.epoch ?? 0;
    if (epoch != _interactionEpoch) {
      _interactionEpoch = epoch;
      sessionGeneration++;
      clearPendingInteraction();
    }
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    foreground = state == null || state == AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed && foreground) {
          setState(() {
            foreground = false;
            sessionGeneration++;
            clearPendingInteraction();
          });
        } else if (state == AppLifecycleState.resumed && !foreground) {
          setState(() => foreground = true);
          resumeMediaSession();
        }
      },
    );
  }

  void clearPendingInteraction() {}

  void resumeMediaSession() {}

  /// Observe configuration only; constructing this guard performs no network
  /// checks and never puts credentials in keys, error text, or diagnostics.
  void watchMediaAccounts({bool jellyfinOnly = false}) {
    watchMediaAccount(IntegrationId.jellyfin, jellyfinConnectionProvider);
    if (jellyfinOnly) return;
    watchMediaAccount(IntegrationId.jellyseerr, jellyseerrConnectionProvider);
    watchMediaAccount(IntegrationId.sonarr, sonarrConnectionProvider);
    watchMediaAccount(IntegrationId.radarr, radarrConnectionProvider);
    watchMediaAccount(IntegrationId.bazarr, bazarrConnectionProvider);
  }

  /// Call directly from ConsumerState.build for each relevant connection.
  /// Resolving local saved configuration does not perform a service read.
  void watchMediaAccount<C>(
    IntegrationId id,
    ProviderListenable<AsyncValue<C>> provider,
  ) {
    final value = ref.watch(provider);
    if (!_accounts.containsKey(id) && !value.isLoading && !value.hasError) {
      _accounts[id] = value.value;
    }
    ref.listen(provider, (previous, next) {
      if (!_accounts.containsKey(id)) return;
      final unresolved = next.isLoading || next.hasError;
      final changed =
          !unresolved && !sameHealthConfiguration(_accounts[id], next.value);
      if (unresolved && _unresolvedAccounts.contains(id)) return;
      setState(() {
        if (unresolved) {
          _unresolvedAccounts.add(id);
        } else {
          _unresolvedAccounts.remove(id);
          _accountChanged = _accountChanged || changed;
        }
        if (unresolved || changed) {
          sessionGeneration++;
          clearPendingInteraction();
        }
        sessionExpired = _accountChanged || _unresolvedAccounts.isNotEmpty;
      });
    });
  }

  bool sessionCurrent(int generation) =>
      mounted &&
      foreground &&
      interactionActive &&
      !sessionExpired &&
      generation == sessionGeneration;

  VoidCallback guardedMediaAction(VoidCallback action) {
    final generation = sessionGeneration;
    return () {
      if (sessionCurrent(generation)) action();
    };
  }

  @override
  void dispose() {
    sessionGeneration++;
    _interaction?.removeListener(_interactionChanged);
    _lifecycle.dispose();
    super.dispose();
  }
}
