import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/home_session_controller.dart';
import '../../../../core/home_source_store.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../media/hub/presentation/media_hub_screen.dart';
import '../../../media/jellyfin/providers/jellyfin_providers.dart';
import '../../../server/data/server_account_controller.dart';
import '../../../server/media_rows/data/server_media_rows_controller.dart';
import '../../../server/providers/server_providers.dart';
import '../../domain/tile_config.dart';
import 'service_tile_shell.dart';
import '../../../settings/data/app_service.dart';

class JellyfinTile extends ConsumerWidget {
  const JellyfinTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final home = ref.watch(homeSessionControllerProvider);
    if (home != null && home.source != HomeSource.directLocal) {
      return const _CoreJellyfinTile();
    }
    final connected = ref.watch(jellyfinConnectionProvider).value != null;
    final items = ref.watch(jellyfinResumeItemsProvider).value ?? const [];

    return ServiceTileShell(
      icon: CupertinoIcons.play_rectangle,
      service: AppService.jellyfin,
      title: 'Jellyfin',
      connected: connected,
      onTap: () =>
          Navigator.of(context)
              .push(CupertinoPageRoute(builder: (_) => const MediaHubScreen())),
      lines: items.isEmpty
          ? [AppLocalizations.of(context).jellyfinTileNothingInProgress]
          : items.take(3).map((item) => item.name).toList(),
    );
  }
}

final class _CoreJellyfinTile extends ConsumerStatefulWidget {
  const _CoreJellyfinTile();

  @override
  ConsumerState<_CoreJellyfinTile> createState() => _CoreJellyfinTileState();
}

final class _CoreJellyfinTileState extends ConsumerState<_CoreJellyfinTile>
    with WidgetsBindingObserver {
  late final ServerAccountController _account;
  late final ServerMediaRowsController _controller;
  late final HomeSessionController _home;
  late final int _accountGeneration;
  late final Object _homeIdentity;
  late final int _interactionEpoch;
  ValueListenable<TickerModeData>? _ticker;
  Animation<double>? _secondaryRouteAnimation;
  int _lifecycle = 0;
  bool _resumed = false;
  bool _visible = true;
  bool _routeCovered = false;

  bool get _active =>
      mounted &&
      _resumed &&
      _visible &&
      !_routeCovered &&
      identical(ref.read(homeSessionControllerProvider), _home) &&
      _home.source == HomeSource.verifiedCore &&
      !_home.busy &&
      _home.failure == null &&
      identical(_home.runtimeIdentity, _homeIdentity) &&
      _home.interaction.active &&
      _home.interaction.epoch == _interactionEpoch &&
      _account.isCurrent(_accountGeneration) &&
      _account.initialized &&
      !_account.working &&
      !_account.hasPendingContext &&
      _account.session?.context != null &&
      _account.session?.authMutationPending == false &&
      _account.session?.user.mustChangePassword == false &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resumed =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _home = ref.read(homeSessionControllerProvider)!;
    _homeIdentity = _home.runtimeIdentity;
    _interactionEpoch = _home.interaction.epoch;
    _account = ref.read(serverAccountControllerProvider);
    _accountGeneration = _account.generation;
    _controller = ServerMediaRowsController(_account);
    _account.addListener(_accountChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ticker = TickerMode.getValuesNotifier(context);
    if (!identical(ticker, _ticker)) {
      _ticker?.removeListener(_visibilityChanged);
      _ticker = ticker;
      _visible = ticker.value.enabled;
      ticker.addListener(_visibilityChanged);
    }
    final secondary = ModalRoute.of(context)?.secondaryAnimation;
    if (!identical(secondary, _secondaryRouteAnimation)) {
      _secondaryRouteAnimation?.removeListener(_routeVisibilityChanged);
      _secondaryRouteAnimation = secondary;
      _routeCovered = (secondary?.value ?? 0) > 0;
      secondary?.addListener(_routeVisibilityChanged);
    }
  }

  void _routeVisibilityChanged() {
    final covered = (_secondaryRouteAnimation?.value ?? 0) > 0;
    if (_routeCovered == covered) return;
    _routeCovered = covered;
    if (covered) {
      _lifecycle++;
      _controller.retire();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    }
  }

  void _visibilityChanged() {
    final visible = _ticker?.value.enabled ?? true;
    if (_visible == visible) return;
    _visible = visible;
    if (visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    } else {
      _lifecycle++;
      _controller.retire();
    }
  }

  void _accountChanged() {
    if (!_account.isCurrent(_accountGeneration) || _account.session == null) {
      _controller.retire();
      return;
    }
    _refresh();
  }

  void _refresh() {
    final lifecycle = _lifecycle;
    unawaited(
      _controller.refresh(current: () => _active && lifecycle == _lifecycle),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (_resumed) {
      _refresh();
    } else {
      _lifecycle++;
      _controller.retire();
    }
  }

  @override
  void dispose() {
    _lifecycle++;
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.removeListener(_visibilityChanged);
    _secondaryRouteAnimation?.removeListener(_routeVisibilityChanged);
    _account.removeListener(_accountChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final l10n = AppLocalizations.of(context);
      final rows = _controller.value?.rows.resume ?? const [];
      final valueAvailable = _controller.value != null;
      return ServiceTileShell(
        icon: CupertinoIcons.play_rectangle,
        service: AppService.jellyfin,
        observeService: false,
        title: 'Jellyfin',
        connected: valueAvailable,
        transientStatus: _controller.busy
            ? l10n.commonLoading
            : _controller.failure != null
            ? l10n.commonError
            : null,
        onTap: () => Navigator.of(context)
            .push(CupertinoPageRoute(builder: (_) => const MediaHubScreen())),
        lines: rows.isEmpty
            ? [l10n.jellyfinTileNothingInProgress]
            : rows.take(3).map((item) => item.title).toList(),
      );
    },
  );
}
