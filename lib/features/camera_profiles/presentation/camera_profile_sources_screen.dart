import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../data/camera_profile_api.dart';
import '../domain/camera_source_models.dart';

class CameraProfileSourcesScreen extends StatefulWidget {
  const CameraProfileSourcesScreen({
    super.key,
    required this.api,
    required this.onDone,
  });
  final CoreCameraProfileApi api;
  final VoidCallback onDone;
  @override
  State<CameraProfileSourcesScreen> createState() =>
      _CameraProfileSourcesScreenState();
}

class _CameraDraft {
  _CameraDraft({this.recording, this.detection, this.area});
  String? recording, detection, area;
}

class _CameraProfileSourcesScreenState
    extends State<CameraProfileSourcesScreen> {
  CameraSourceState? _source;
  final _cameras = <_CameraDraft>[];
  List<CameraSourceRecovery> _recoveries = const [];
  String? _presence;
  bool _busy = true, _failed = false, _saved = false;
  int _enter = 30, _exit = 120, _hysteresis = 10, _maxAge = 120;
  final _home = {'recording': 'paused', 'detection': 'disabled'};
  final _away = {'recording': 'enabled', 'detection': 'enabled'};
  final _failSafe = {'recording': 'enabled', 'detection': 'enabled'};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _failed = false;
      _saved = false;
    });
    try {
      final source = await widget.api.sources();
      var recoveries = <CameraSourceRecovery>[];
      var recoveryFailed = false;
      if (source.revision > 0) {
        try {
          recoveries = await widget.api.sourceRecoveries();
        } catch (_) {
          // Preserve the editable bindings when an old unknown command's
          // provider is offline; the administrator can repair its sources.
          recoveryFailed = true;
        }
      }
      if (!mounted) return;
      final settings = source.settings;
      setState(() {
        _source = source;
        _recoveries = recoveries;
        _failed = recoveryFailed;
        _busy = false;
        _cameras.clear();
        _presence = settings?['presenceResourceId'] as String?;
        if (settings != null) {
          for (final raw in settings['cameras'] as List) {
            final item = raw as Map;
            _cameras.add(
              _CameraDraft(
                recording: item['recordingResourceId'] as String,
                detection: item['detectionResourceId'] as String,
                area: item['areaId'] as String,
              ),
            );
          }
          _enter = (settings['enterDelayMs'] as int) ~/ 1000;
          _exit = (settings['exitDelayMs'] as int) ~/ 1000;
          _hysteresis = (settings['hysteresisMs'] as int) ~/ 1000;
          _maxAge = (settings['presenceMaxAgeMs'] as int) ~/ 1000;
          for (final pair in [
            (_home, 'atHomeMode'),
            (_away, 'awayMode'),
            (_failSafe, 'failSafeMode'),
          ]) {
            final mode = settings[pair.$2] as Map;
            pair.$1.addAll({
              'recording': mode['recording'] as String,
              'detection': mode['detection'] as String,
            });
          }
        }
        if (_cameras.isEmpty) _cameras.add(_CameraDraft());
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _failed = true;
          _source = null;
        });
      }
    }
  }

  Future<void> _reconcile(CameraSourceRecovery recovery) async {
    if (_busy) return;
    final l10n = AppLocalizations.of(context);
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(recovery.label),
        content: Text(
          '${l10n.cameraProfileRecoveryHelp}\n\n'
          '${l10n.cameraProfileRecordingSource}: ${recovery.recording == 'enabled' ? l10n.cameraProfileEnabled : l10n.cameraProfilePaused}\n'
          '${l10n.cameraProfileDetectionSource}: ${recovery.detection == 'enabled' ? l10n.cameraProfileEnabled : l10n.cameraProfileDisabled}',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.cameraProfileRecoverSource),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true || _busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await widget.api.reconcileSource(recovery);
      if (mounted) await _load();
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _failed = true;
          _source = null;
        });
      }
    }
  }

  bool get _valid {
    final source = _source;
    if (source == null || _presence == null || _cameras.isEmpty) return false;
    final known = source.resources.map((value) => value.id).toSet();
    final areas = source.areas.map((value) => value.id).toSet();
    final used = <String>{_presence!};
    if (!known.contains(_presence)) return false;
    for (final camera in _cameras) {
      if (camera.recording == null ||
          camera.detection == null ||
          camera.area == null ||
          !known.contains(camera.recording) ||
          !known.contains(camera.detection) ||
          !areas.contains(camera.area) ||
          !used.add(camera.recording!) ||
          !used.add(camera.detection!)) {
        return false;
      }
    }
    return true;
  }

  Future<void> _save() async {
    if (_busy || !_valid) return;
    setState(() {
      _busy = true;
      _failed = false;
      _saved = false;
    });
    final body = <String, dynamic>{
      'schemaVersion': 1,
      'expectedRevision': _source!.revision,
      'presenceResourceId': _presence,
      'cameras': [
        for (final camera in _cameras)
          {
            'recordingResourceId': camera.recording,
            'detectionResourceId': camera.detection,
            'areaId': camera.area,
          },
      ],
      'enterDelayMs': _enter * 1000,
      'exitDelayMs': _exit * 1000,
      'hysteresisMs': _hysteresis * 1000,
      'presenceMaxAgeMs': _maxAge * 1000,
      'atHomeMode': Map<String, String>.of(_home),
      'awayMode': Map<String, String>.of(_away),
      'failSafeMode': Map<String, String>.of(_failSafe),
    };
    try {
      CameraSourceState.validateSettings(body);
      final saved = await widget.api.configureSources(body);
      if (mounted) {
        setState(() {
          _source = saved;
          _busy = false;
          _saved = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _failed = true;
          _source = null;
        });
      }
    }
  }

  String _name(List<CameraSourceChoice> choices, String? id) {
    for (final choice in choices) {
      if (choice.id == id) return choice.name;
    }
    return AppLocalizations.of(context).cameraProfileChooseSource;
  }

  Future<void> _choose(
    String title,
    List<CameraSourceChoice> choices,
    void Function(String) accept,
  ) async {
    if (_busy) return;
    final picked = await showCupertinoModalPopup<String>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(title),
        actions: [
          for (final choice in choices)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(context).pop(choice.id),
              child: Text(choice.name),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppLocalizations.of(context).commonCancel),
        ),
      ),
    );
    if (mounted && picked != null && !_busy) {
      setState(() {
        accept(picked);
        _saved = false;
      });
    }
  }

  Widget _choice(
    String title,
    String? value,
    List<CameraSourceChoice> choices,
    void Function(String) accept,
  ) => SettingsActionTile(
    title: Text(title),
    additionalInfo: Text(_name(choices, value)),
    onTap: _busy || choices.isEmpty
        ? null
        : () => _choose(title, choices, accept),
  );

  Widget _duration(
    String title,
    int value,
    int minimum,
    int maximum,
    void Function(int) accept,
  ) => SettingsActionTile(
    title: Text(title),
    additionalInfo: Text('$value'),
    onTap: _busy
        ? null
        : () async {
            final input = TextEditingController(text: '$value');
            final picked = await showCupertinoDialog<int>(
              context: context,
              builder: (context) => CupertinoAlertDialog(
                title: Text(title),
                content: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: CupertinoTextField(
                    controller: input,
                    keyboardType: TextInputType.number,
                    autofocus: true,
                    placeholder: '$minimum–$maximum',
                    maxLength: 5,
                  ),
                ),
                actions: [
                  CupertinoDialogAction(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(AppLocalizations.of(context).commonCancel),
                  ),
                  CupertinoDialogAction(
                    onPressed: () {
                      final number = int.tryParse(input.text.trim());
                      if (number != null &&
                          number >= minimum &&
                          number <= maximum) {
                        Navigator.of(context).pop(number);
                      }
                    },
                    child: Text(AppLocalizations.of(context).commonSave),
                  ),
                ],
              ),
            );
            input.dispose();
            if (mounted && picked != null && !_busy) {
              setState(() {
                accept(picked);
                _saved = false;
              });
            }
          },
  );

  Widget _mode(
    String title,
    Map<String, String> mode, {
    bool failSafe = false,
  }) {
    final l10n = AppLocalizations.of(context);
    return SettingsSection(
      header: Text(title),
      children: [
        SettingsActionTile(
          title: Text(l10n.cameraProfileRecordingSource),
          additionalInfo: Text(
            mode['recording'] == 'enabled'
                ? l10n.cameraProfileEnabled
                : l10n.cameraProfilePaused,
          ),
          onTap: _busy || failSafe
              ? null
              : () => setState(() {
                  mode['recording'] = mode['recording'] == 'enabled'
                      ? 'paused'
                      : 'enabled';
                  _saved = false;
                }),
        ),
        SettingsActionTile(
          title: Text(l10n.cameraProfileDetectionSource),
          additionalInfo: Text(
            mode['detection'] == 'enabled'
                ? l10n.cameraProfileEnabled
                : l10n.cameraProfileDisabled,
          ),
          onTap: _busy
              ? null
              : () => setState(() {
                  mode['detection'] = mode['detection'] == 'enabled'
                      ? 'disabled'
                      : 'enabled';
                  _saved = false;
                }),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context), source = _source;
    final switches =
        source?.resources.where((item) => item.domain == 'switch').toList() ??
        <CameraSourceChoice>[];
    final presence =
        source?.resources.where((item) => item.domain != 'switch').toList() ??
        <CameraSourceChoice>[];
    return ServiceRootScaffold(
      title: l10n.cameraProfileSources,
      trailing: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: _busy ? null : widget.onDone,
        child: Text(l10n.cameraProfileReturnToProfile),
      ),
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            footer: Text(l10n.cameraProfileSourceDescription),
            children: [
              if (_busy)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: CupertinoActivityIndicator()),
                ),
              if (_failed)
                Semantics(
                  liveRegion: true,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(l10n.cameraProfileSourcesFailed),
                  ),
                ),
              if (_saved)
                Semantics(
                  liveRegion: true,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(l10n.cameraProfileSourcesSaved),
                  ),
                ),
              SettingsActionTile(
                title: Text(l10n.cameraProfileReconnect),
                leading: const Icon(CupertinoIcons.refresh),
                onTap: _busy ? null : _load,
              ),
              _choice(
                l10n.cameraProfilePresenceSource,
                _presence,
                presence,
                (id) => _presence = id,
              ),
            ],
          ),
        ),
        if (source != null) ...[
          if (_recoveries.isNotEmpty)
            SliverToBoxAdapter(
              child: SettingsSection(
                header: Text(l10n.cameraProfileRecoveryTitle),
                footer: Text(l10n.cameraProfileRecoveryHelp),
                children: [
                  for (final recovery in _recoveries)
                    SettingsActionTile(
                      title: Text(recovery.label),
                      additionalInfo: Text(l10n.cameraProfileRecoverSource),
                      onTap: _busy ? null : () => _reconcile(recovery),
                    ),
                ],
              ),
            ),
          for (final camera in _cameras)
            SliverToBoxAdapter(
              child: SettingsSection(
                children: [
                  _choice(
                    l10n.cameraProfileRecordingSource,
                    camera.recording,
                    switches,
                    (id) => camera.recording = id,
                  ),
                  _choice(
                    l10n.cameraProfileDetectionSource,
                    camera.detection,
                    switches,
                    (id) => camera.detection = id,
                  ),
                  _choice(
                    l10n.cameraProfileAreaSource,
                    camera.area,
                    source.areas,
                    (id) => camera.area = id,
                  ),
                  SettingsActionTile(
                    title: Text(l10n.cameraProfileRemoveCamera),
                    leading: const Icon(CupertinoIcons.minus_circle),
                    onTap: _busy
                        ? null
                        : () => setState(() {
                            _cameras.remove(camera);
                            _saved = false;
                          }),
                  ),
                ],
              ),
            ),
          SliverToBoxAdapter(
            child: SettingsSection(
              children: [
                SettingsActionTile(
                  title: Text(l10n.cameraProfileAddCamera),
                  leading: const Icon(CupertinoIcons.add),
                  onTap: _busy || _cameras.length >= 16
                      ? null
                      : () => setState(() {
                          _cameras.add(_CameraDraft());
                          _saved = false;
                        }),
                ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: SettingsSection(
              footer: Text(l10n.cameraProfileTimingHelp),
              children: [
                _duration(
                  l10n.cameraProfileEnterDelay,
                  _enter,
                  0,
                  3600,
                  (value) => _enter = value,
                ),
                _duration(
                  l10n.cameraProfileExitDelay,
                  _exit,
                  0,
                  3600,
                  (value) => _exit = value,
                ),
                _duration(
                  l10n.cameraProfileHysteresis,
                  _hysteresis,
                  0,
                  900,
                  (value) => _hysteresis = value,
                ),
                _duration(
                  l10n.cameraProfilePresenceAge,
                  _maxAge,
                  1,
                  86400,
                  (value) => _maxAge = value,
                ),
              ],
            ),
          ),
          SliverToBoxAdapter(child: _mode(l10n.cameraProfileAtHomeMode, _home)),
          SliverToBoxAdapter(child: _mode(l10n.cameraProfileAwayMode, _away)),
          SliverToBoxAdapter(
            child: _mode(
              l10n.cameraProfileFailSafeMode,
              _failSafe,
              failSafe: true,
            ),
          ),
        ],
        SliverToBoxAdapter(
          child: SettingsSection(
            children: [
              SettingsActionTile(
                buttonKey: const ValueKey('camera-sources-save'),
                title: Text(l10n.cameraProfileSaveSources),
                leading: const Icon(CupertinoIcons.checkmark_shield),
                onTap: _busy || !_valid ? null : _save,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
