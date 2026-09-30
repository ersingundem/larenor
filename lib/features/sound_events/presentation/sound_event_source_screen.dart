import 'package:flutter/cupertino.dart';

import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../data/core_sound_event_api.dart';
import '../domain/sound_event_source_models.dart';

class SoundEventSourceScreen extends StatefulWidget {
  const SoundEventSourceScreen({
    super.key,
    required this.api,
    required this.setup,
    required this.onConfigured,
    required this.onCancel,
  });
  final SoundSourceConfigurationApi api;
  final SoundSourceSetup setup;
  final ValueChanged<SoundSourceSetup> onConfigured;
  final VoidCallback? onCancel;

  @override
  State<SoundEventSourceScreen> createState() => _SoundEventSourceScreenState();
}

class _SoundEventSourceScreenState extends State<SoundEventSourceScreen> {
  SoundSourceChoice? _camera, _room;
  bool _consent = false, _busy = false, _failed = false;

  bool get _tr => Localizations.localeOf(context).languageCode == 'tr';

  @override
  void initState() {
    super.initState();
    final config = widget.setup.configuration;
    _camera = widget.setup.cameras.cast<SoundSourceChoice?>().firstWhere(
      (item) => item?.id == config?.cameraResourceId,
      orElse: () => widget.setup.cameras.firstOrNull,
    );
    _room = widget.setup.rooms.cast<SoundSourceChoice?>().firstWhere(
      (item) => item?.id == config?.roomId,
      orElse: () => widget.setup.rooms.firstOrNull,
    );
    _consent = config?.consentGranted ?? false;
  }

  Future<void> _pick(List<SoundSourceChoice> choices, bool camera) async {
    if (_busy || choices.isEmpty) return;
    final selected = await showCupertinoModalPopup<SoundSourceChoice>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(
          camera
              ? (_tr ? 'Frigate kamerası' : 'Frigate camera')
              : (_tr ? 'Oda' : 'Room'),
        ),
        actions: [
          for (final item in choices)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, item),
              child: Text(item.label),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: Text(_tr ? 'Vazgeç' : 'Cancel'),
        ),
      ),
    );
    if (selected != null && mounted) {
      setState(() => camera ? _camera = selected : _room = selected);
    }
  }

  Future<void> _save() async {
    final camera = _camera, room = _room;
    if (_busy || camera == null || room == null) return;
    final existing = widget.setup.configuration;
    final bark = _consent
        ? (camera.audioLabels.contains('bark') ? ['bark'] : <String>[])
        : (existing?.labels['bark'] ?? const <String>[]);
    const noiseAllowlist = {
      'fire_alarm',
      'smoke_detector',
      'yell',
      'scream',
      'shatter',
      'breaking',
      'gunshot',
      'explosion',
    };
    final noise = _consent
        ? camera.audioLabels.where(noiseAllowlist.contains).toList()
        : (existing?.labels['noise'] ?? const <String>[]);
    if (_consent && bark.isEmpty && noise.isEmpty) {
      setState(() => _failed = true);
      return;
    }
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final result = await widget.api.configureSource(
        current: widget.setup,
        camera: camera,
        room: room,
        barkLabels: bark,
        noiseLabels: noise,
        consentGranted: _consent,
        retentionSeconds: existing?.retentionSeconds ?? 24 * 60 * 60,
      );
      if (mounted) widget.onConfigured(result);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ServiceRootScaffold(
    title: _tr ? 'Ses kaynağı' : 'Sound source',
    slivers: [
      SliverToBoxAdapter(
        child: SettingsSection(
          header: Text(_tr ? 'Frigate ses olayları' : 'Frigate audio events'),
          footer: Text(
            _tr
                ? 'Ham ses veya klip saklanmaz. Olay olmaması sessizlik kanıtı değildir.'
                : 'Raw audio and clips are never stored. No event is not proof of silence.',
          ),
          children: [
            SettingsActionTile(
              buttonKey: const ValueKey('sound-source-camera'),
              leading: const Icon(CupertinoIcons.video_camera),
              title: Text(_tr ? 'Kamera' : 'Camera'),
              additionalInfo: Text(
                _camera?.label ?? (_tr ? 'Seçilmedi' : 'Not selected'),
              ),
              onTap: _busy ? null : () => _pick(widget.setup.cameras, true),
            ),
            SettingsActionTile(
              buttonKey: const ValueKey('sound-source-room'),
              leading: const Icon(CupertinoIcons.house),
              title: Text(_tr ? 'Oda' : 'Room'),
              additionalInfo: Text(
                _room?.label ?? (_tr ? 'Seçilmedi' : 'Not selected'),
              ),
              onTap: _busy ? null : () => _pick(widget.setup.rooms, false),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _tr
                          ? 'Bu hesap için ses olayı izlemeye izin ver'
                          : 'Allow sound-event monitoring for this account',
                    ),
                  ),
                  CupertinoSwitch(
                    key: const ValueKey('sound-source-consent'),
                    value: _consent,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _consent = value),
                  ),
                ],
              ),
            ),
            if (_failed)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _tr
                      ? 'Kaynak doğrulanamadı veya desteklenen ses etiketi yok.'
                      : 'The source could not be verified or has no supported audio label.',
                ),
              ),
            SettingsActionTile(
              buttonKey: const ValueKey('sound-source-save'),
              leading: _busy
                  ? const CupertinoActivityIndicator()
                  : const Icon(CupertinoIcons.check_mark_circled),
              title: Text(
                _consent
                    ? (_tr
                          ? 'Kaynağı doğrula ve kaydet'
                          : 'Verify and save source')
                    : (_tr ? 'İzni geri çek' : 'Revoke consent'),
              ),
              onTap: _busy || (!_consent && widget.setup.configuration == null)
                  ? null
                  : _save,
            ),
            if (widget.onCancel case final cancel?)
              SettingsActionTile(
                buttonKey: const ValueKey('sound-source-cancel'),
                leading: const Icon(CupertinoIcons.clear),
                title: Text(_tr ? 'Geri dön' : 'Go back'),
                onTap: _busy ? null : cancel,
              ),
          ],
        ),
      ),
    ],
  );
}
