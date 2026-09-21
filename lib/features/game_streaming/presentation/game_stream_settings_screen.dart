import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/icon_badge.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../settings/presentation/panes/settings_nav_row.dart';
import '../data/android_game_stream_port.dart';

class GameStreamSettingsScreen extends StatefulWidget {
  const GameStreamSettingsScreen({super.key, this.port, this.gateCurrent});

  final GameStreamCapabilityPort? port;
  final bool Function()? gateCurrent;

  @override
  State<GameStreamSettingsScreen> createState() =>
      _GameStreamSettingsScreenState();
}

class _GameStreamSettingsScreenState extends State<GameStreamSettingsScreen>
    with WidgetsBindingObserver {
  late final GameStreamCapabilityPort _port;
  AppInteractionController? _interaction;
  ModalRoute<dynamic>? _route;
  int _generation = 0;
  int _interactionEpoch = 0;
  bool _resumed = true;
  bool _focused = true;
  bool _routeVisible = false;
  bool _loading = false;
  bool _started = false;
  AndroidGameStreamCapabilities? _capabilities;
  String? _error;

  @override
  void initState() {
    super.initState();
    _port = widget.port ?? AndroidGameStreamPort();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final interaction = AppInteractionScope.maybeOf(context);
    if (!identical(interaction, _interaction)) {
      _interaction?.removeListener(_interactionChanged);
      _interaction = interaction;
      _interactionEpoch = interaction?.epoch ?? 0;
      interaction?.addListener(_interactionChanged);
      _invalidate(clearStatus: false);
    }
    final route = ModalRoute.of(context);
    if (_route != null && !identical(route, _route)) {
      _invalidate(clearStatus: true);
    }
    _route = route;
    final routeVisible =
        route?.isCurrent == true && TickerMode.valuesOf(context).enabled;
    if (_routeVisible && !routeVisible) {
      _invalidate(clearStatus: true);
    }
    _routeVisible = routeVisible;
    if (!_started) {
      _started = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_refresh());
      });
    }
  }

  void _interactionChanged() {
    final epoch = _interaction?.epoch ?? 0;
    if (epoch == _interactionEpoch) return;
    _interactionEpoch = epoch;
    _invalidate(clearStatus: true);
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (!_resumed) _invalidate(clearStatus: true);
    if (mounted) setState(() {});
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (!mounted || event.viewId != View.of(context).viewId) return;
    _focused = event.state == ViewFocusState.focused;
    if (!_focused) _invalidate(clearStatus: true);
    setState(() {});
  }

  void _invalidate({required bool clearStatus}) {
    _generation += 1;
    _loading = false;
    if (clearStatus) {
      _capabilities = null;
      _error = null;
    }
  }

  bool _current(int generation) {
    try {
      return mounted &&
          generation == _generation &&
          _resumed &&
          _focused &&
          _interaction?.active != false &&
          (_interaction?.epoch ?? 0) == _interactionEpoch &&
          widget.gateCurrent?.call() == true &&
          identical(ModalRoute.of(context), _route) &&
          _route?.isCurrent == true &&
          TickerMode.valuesOf(context).enabled;
    } catch (_) {
      return false;
    }
  }

  Future<void> _refresh() async {
    final generation = ++_generation;
    if (!_current(generation)) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final capabilities = await _port.capabilities();
      if (!_current(generation)) return;
      setState(() {
        _capabilities = capabilities;
        _loading = false;
      });
    } catch (_) {
      if (!_current(generation)) return;
      setState(() {
        _capabilities = null;
        _error = 'capability_read_failed';
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _generation += 1;
    _interaction?.removeListener(_interactionChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final status = _loading
        ? l10n.gameStreamingChecking
        : _error != null
        ? l10n.gameStreamingError
        : _capabilities?.available == true
        ? l10n.gameStreamingAvailable
        : _capabilities != null
        ? l10n.gameStreamingUnavailable
        : l10n.gameStreamingNotChecked;
    final statusColor = _loading
        ? CupertinoColors.systemBlue
        : _error != null
        ? CupertinoColors.systemRed
        : _capabilities?.available == true
        ? CupertinoColors.systemGreen
        : _capabilities != null
        ? CupertinoColors.systemOrange
        : CupertinoColors.secondaryLabel;
    final current = _current(_generation);

    return SettingsPaneScaffold(
      title: l10n.gameStreamingTitle,
      children: [
        SettingsSection(
          header: Semantics(
            key: const ValueKey('game-stream-engine-header'),
            header: true,
            child: Text(l10n.gameStreamingEngineHeader),
          ),
          footer: Text(l10n.gameStreamingDeferredBody),
          children: [
            Semantics(
              key: const ValueKey('game-stream-status'),
              container: true,
              liveRegion: true,
              label: '${l10n.gameStreamingEngineHeader}. $status',
              child: ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        _capabilities?.available == true
                            ? CupertinoIcons.checkmark_circle_fill
                            : CupertinoIcons.game_controller_solid,
                        color: statusColor.resolveFrom(context),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(status)),
                    ],
                  ),
                ),
              ),
            ),
            SettingsActionTile(
              buttonKey: const ValueKey('game-stream-refresh'),
              leading: const IconBadge(
                icon: CupertinoIcons.refresh,
                color: CupertinoColors.systemBlue,
              ),
              title: Text(l10n.gameStreamingCheckAgain),
              onTap: current && !_loading ? () => unawaited(_refresh()) : null,
            ),
          ],
        ),
        SettingsSection(
          header: Semantics(
            key: const ValueKey('game-stream-boundary-header'),
            header: true,
            child: Text(l10n.gameStreamingBoundaryHeader),
          ),
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(l10n.gameStreamingBoundaryBody),
            ),
          ],
        ),
      ],
    );
  }
}
