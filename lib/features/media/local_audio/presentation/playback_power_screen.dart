import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../../../shared/widgets/settings_action_tile.dart';
import '../../../../shared/widgets/settings_section.dart';
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() {
      _foreground = state == AppLifecycleState.resumed;
      _generation++;
      _reading = false;
    });
    if (_foreground) _refresh();
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool get _active =>
      mounted && _foreground && TickerMode.valuesOf(context).enabled;

  Future<void> _refresh() async {
    if (!_active || _reading) return;
    final generation = _generation;
    setState(() {
      _reading = true;
      _error = null;
      _status = null;
    });
    try {
      final result = await ref.read(localAudioBridgeProvider).readPowerStatus();
      if (_active && generation == _generation) {
        setState(() => _status = result);
      }
    } catch (_) {
      if (_active && generation == _generation) {
        setState(() => _error = AppLocalizations.of(context).healthReadError);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _reading = false);
      }
    }
  }

  Future<void> _open(bool battery) async {
    if (!_active || _opening || ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    setState(() {
      _opening = true;
      _error = null;
    });
    final generation = _generation;
    try {
      final bridge = ref.read(localAudioBridgeProvider);
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
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
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
                CupertinoListTile(
                  title: Text(l10n.commonLoading),
                  trailing: const CupertinoActivityIndicator(),
                ),
              if (_error != null) CupertinoListTile(title: Text(_error!)),
              if (_status?.supported == false)
                CupertinoListTile(title: Text(l10n.localAudioUnsupported)),
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
                  onTap: _active && !_opening ? () => _open(true) : null,
                ),
                SettingsActionTile(
                  buttonKey: const ValueKey('local-audio-open-notifications'),
                  leading: const Icon(CupertinoIcons.bell),
                  title: Text(l10n.localAudioOpenNotifications),
                  onTap: _active && !_opening ? () => _open(false) : null,
                ),
              ],
              SettingsActionTile(
                buttonKey: const ValueKey('local-audio-power-refresh'),
                leading: const Icon(CupertinoIcons.refresh),
                title: Text(l10n.commonRefresh),
                onTap: _active && !_reading ? _refresh : null,
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
