import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
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
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.localAudioPowerTitle),
      ),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(l10n.localAudioPowerHint, style: AppText.body),
                const SizedBox(height: 20),
                if (_reading) const CupertinoActivityIndicator(),
                if (_error != null) Text(_error!),
                if (_status?.supported == false)
                  Text(l10n.localAudioUnsupported),
                if (supported) ...[
                  _row(
                    l10n.localAudioNotifications,
                    flag(_status!.notificationsEnabled),
                  ),
                  _row(
                    l10n.localAudioBackgroundRestricted,
                    flag(_status!.backgroundRestricted),
                  ),
                  _row(
                    l10n.localAudioBatteryExempt,
                    flag(_status!.batteryOptimizationExempt),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.localAudioMediaNotificationHint,
                    style: AppText.footnote,
                  ),
                  const SizedBox(height: 16),
                  CupertinoButton(
                    onPressed: _active && !_opening ? () => _open(true) : null,
                    child: Text(l10n.localAudioOpenBattery),
                  ),
                  CupertinoButton(
                    onPressed: _active && !_opening ? () => _open(false) : null,
                    child: Text(l10n.localAudioOpenNotifications),
                  ),
                ],
                CupertinoButton(
                  onPressed: _active && !_reading ? _refresh : null,
                  child: Text(l10n.commonRefresh),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(String title, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Wrap(
      spacing: 12,
      runSpacing: 8,
      alignment: WrapAlignment.spaceBetween,
      children: [
        Text(title, style: AppText.headline),
        Text(value, style: AppText.body),
      ],
    ),
  );
}
