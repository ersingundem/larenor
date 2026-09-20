import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/app_interaction_scope.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../../../shared/widgets/settings_action_tile.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../data/local_audio_bridge.dart';
import '../domain/local_audio_models.dart';
import '../providers/local_audio_providers.dart';

class PlaybackPowerScreen extends ConsumerStatefulWidget {
  const PlaybackPowerScreen({super.key});
  @override
  ConsumerState<PlaybackPowerScreen> createState() =>
      _PlaybackPowerScreenState();
}

class _PlaybackPowerScreenState extends ConsumerState<PlaybackPowerScreen>
    with WidgetsBindingObserver {
  LocalAudioPowerStatus? _status;
  String? _error;
  bool _reading = false;
  bool _opening = false;
  int _generation = 0;
  bool _foreground = true;
  bool _visible = true;
  ValueListenable<TickerModeData>? _ticker;
  AppInteractionController? _interaction;
  int? _interactionEpoch;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = TickerMode.getValuesNotifier(context);
    if (!identical(next, _ticker)) {
      _ticker?.removeListener(_visibilityChanged);
      _ticker = next;
      _visible = next.value.enabled;
      next.addListener(_visibilityChanged);
    }
    final interaction = AppInteractionScope.maybeOf(context);
    if (!identical(interaction, _interaction)) {
      final hadInteraction = _interaction != null;
      _interaction?.removeListener(_interactionChanged);
      _interaction = interaction;
      _interactionEpoch = interaction?.epoch;
      interaction?.addListener(_interactionChanged);
      if (hadInteraction) _expireAuthority(notify: false);
    }
  }

  void _interactionChanged() {
    if (!mounted) return;
    final epoch = _interaction?.epoch;
    if (epoch != _interactionEpoch) {
      _interactionEpoch = epoch;
      _expireAuthority();
      return;
    }
    setState(() {});
    if (_interaction?.active == true && _active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_refresh());
      });
    }
  }

  void _expireAuthority({bool notify = true}) {
    _generation++;
    _reading = false;
    _opening = false;
    _status = null;
    _error = null;
    if (notify && mounted) setState(() {});
  }

  void _visibilityChanged() {
    if (!mounted) return;
    final visible = _ticker?.value.enabled ?? true;
    if (visible == _visible) return;
    _visible = visible;
    _generation++;
    _reading = false;
    _opening = false;
    setState(() {});
    if (visible && _foreground) unawaited(_refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() {
      _foreground = state == AppLifecycleState.resumed;
      _generation++;
      _reading = false;
      _opening = false;
    });
    if (_foreground) _refresh();
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.removeListener(_visibilityChanged);
    _interaction?.removeListener(_interactionChanged);
    super.dispose();
  }

  bool get _active =>
      mounted &&
      _foreground &&
      _visible &&
      _interaction?.active != false &&
      identical(_interaction, AppInteractionScope.maybeRead(context)) &&
      _interaction?.epoch == _interactionEpoch &&
      ModalRoute.of(context)?.isCurrent == true;

  Future<void> _refresh({int? authority, LocalAudioBridge? bridge}) async {
    final currentBridge = ref.read(localAudioBridgeProvider);
    if (!_active ||
        _reading ||
        (authority != null && authority != _generation) ||
        (bridge != null && !identical(bridge, currentBridge))) {
      return;
    }
    final owner = bridge ?? currentBridge;
    final generation = _generation;
    setState(() {
      _reading = true;
      _error = null;
      _status = null;
    });
    try {
      final result = await owner.readPowerStatus();
      if (_active &&
          generation == _generation &&
          identical(owner, ref.read(localAudioBridgeProvider))) {
        setState(() => _status = result);
      }
    } catch (_) {
      if (_active &&
          generation == _generation &&
          identical(owner, ref.read(localAudioBridgeProvider))) {
        setState(() => _error = AppLocalizations.of(context).healthReadError);
      }
    } finally {
      if (mounted &&
          generation == _generation &&
          identical(owner, ref.read(localAudioBridgeProvider))) {
        setState(() => _reading = false);
      }
    }
  }

  Future<void> _open(
    bool battery,
    int authority,
    LocalAudioBridge bridge,
  ) async {
    if (!_active ||
        _opening ||
        authority != _generation ||
        !identical(bridge, ref.read(localAudioBridgeProvider))) {
      return;
    }
    setState(() {
      _opening = true;
      _error = null;
    });
    final generation = _generation;
    try {
      final opened = await (battery
          ? bridge.openBatterySettings()
          : bridge.openNotificationSettings());
      if (!opened && _active && generation == _generation) {
        setState(
          () =>
              _error = AppLocalizations.of(context)
                  .localAudioSettingsUnavailable,
        );
      }
    } catch (_) {
      if (_active && generation == _generation) {
        setState(
          () =>
              _error = AppLocalizations.of(context)
                  .localAudioSettingsUnavailable,
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _opening = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final bridge = ref.watch(localAudioBridgeProvider);
    ref.listen(localAudioBridgeProvider, (previous, next) {
      if (previous == null || identical(previous, next) || !mounted) return;
      setState(() {
        _generation++;
        _reading = false;
        _opening = false;
        _status = null;
        _error = null;
      });
      if (_active) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_refresh(bridge: next));
        });
      }
    });
    final generation = _generation;
    final supported = _status?.supported == true;
    String flag(bool? value) => value == null
        ? l10n.commonUnknown
        : value
        ? l10n.commonYes
        : l10n.commonNo;
    return ServiceRootScaffold(
      title: l10n.localAudioPowerTitle,
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Semantics(
              key: const ValueKey('local-audio-power-section-title'),
              container: true,
              header: true,
              child: Text(l10n.localAudioPowerTitle),
            ),
            footer: Text(l10n.localAudioPowerHint),
            children: [
              if (_reading)
                _PowerStatusTile(label: l10n.commonLoading, loading: true),
              if (_error != null) _PowerStatusTile(label: _error!),
              if (_status?.supported == false)
                _PowerStatusTile(label: l10n.localAudioUnsupported),
              if (supported) ...[
                _PowerStatusRow(
                  title: l10n.localAudioNotifications,
                  value: flag(_status!.notificationsEnabled),
                ),
                _PowerStatusRow(
                  title: l10n.localAudioBackgroundRestricted,
                  value: flag(_status!.backgroundRestricted),
                ),
                _PowerStatusRow(
                  title: l10n.localAudioBatteryExempt,
                  value: flag(_status!.batteryOptimizationExempt),
                ),
              ],
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: SettingsSection(
            footer: supported
                ? Text(l10n.localAudioMediaNotificationHint)
                : null,
            children: [
              if (supported) ...[
                SettingsActionTile(
                  buttonKey: const ValueKey('local-audio-open-battery'),
                  leading: const Icon(CupertinoIcons.battery_100),
                  title: Text(l10n.localAudioOpenBattery),
                  onTap: _active && !_opening
                      ? () => _open(true, generation, bridge)
                      : null,
                ),
                SettingsActionTile(
                  buttonKey: const ValueKey('local-audio-open-notifications'),
                  leading: const Icon(CupertinoIcons.bell),
                  title: Text(l10n.localAudioOpenNotifications),
                  onTap: _active && !_opening
                      ? () => _open(false, generation, bridge)
                      : null,
                ),
              ],
              SettingsActionTile(
                buttonKey: const ValueKey('local-audio-power-refresh'),
                leading: const Icon(CupertinoIcons.refresh),
                title: Text(l10n.commonRefresh),
                onTap: _active && !_reading
                    ? () => _refresh(authority: generation, bridge: bridge)
                    : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PowerStatusRow extends StatelessWidget {
  const _PowerStatusRow({required this.title, required this.value});

  final String title;
  final String value;

  @override
  Widget build(BuildContext context) =>
      CupertinoListTile(title: Text(title), subtitle: Text(value));
}

class _PowerStatusTile extends StatelessWidget {
  const _PowerStatusTile({required this.label, this.loading = false});

  final String label;
  final bool loading;

  @override
  Widget build(BuildContext context) => Semantics(
    key: const ValueKey('local-audio-power-status'),
    container: true,
    liveRegion: true,
    label: label,
    excludeSemantics: true,
    child: CupertinoListTile(
      title: Text(label),
      trailing: loading ? const CupertinoActivityIndicator() : null,
    ),
  );
}
