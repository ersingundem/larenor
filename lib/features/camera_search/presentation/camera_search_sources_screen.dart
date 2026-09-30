import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../data/camera_search_api.dart';
import '../domain/camera_search_source_models.dart';

class CameraSearchSourcesScreen extends StatefulWidget {
  const CameraSearchSourcesScreen({
    super.key,
    required this.api,
    required this.onDone,
  });
  final CameraSearchApi api;
  final VoidCallback onDone;
  @override
  State<CameraSearchSourcesScreen> createState() => _State();
}

class _State extends State<CameraSearchSourcesScreen> {
  CameraSearchSourceState? _source;
  String? _serviceId;
  final _cameras = <String>{};
  bool _busy = true, _failed = false, _saved = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final source = await widget.api.sources();
      if (!mounted) return;
      setState(() {
        _source = source;
        _serviceId = source.serviceId;
        _cameras
          ..clear()
          ..addAll(
            source.cameraIds.where(
              (id) => source.cameras.any((camera) => camera.id == id),
            ),
          );
        _busy = false;
        _saved = false;
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

  CameraSearchSourceChoice? get _selected {
    for (final value in _source?.services ?? <CameraSearchSourceChoice>[]) {
      if (value.id == _serviceId) return value;
    }
    return null;
  }

  bool get _valid =>
      _selected != null &&
      _cameras.isNotEmpty &&
      _cameras.length <= 16 &&
      _cameras.every((id) => _source!.cameras.any((c) => c.id == id));
  Future<void> _choose() async {
    final l = AppLocalizations.of(context);
    final picked = await showCupertinoModalPopup<String>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(l.cameraSearchFrigateService),
        actions: [
          for (final service in _source!.services)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(context).pop(service.id),
              child: Text(service.name),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.commonCancel),
        ),
      ),
    );
    if (mounted && !_busy && picked != null) {
      setState(() {
        _serviceId = picked;
        _saved = false;
      });
    }
  }

  Future<void> _save() async {
    if (_busy || !_valid) return;
    final source = _source!, selected = _selected!;
    setState(() {
      _busy = true;
      _failed = false;
      _saved = false;
    });
    try {
      final saved = await widget.api.configureSources(
        revision: source.revision,
        service: selected,
        cameras: _cameras.toList(),
      );
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

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ServiceRootScaffold(
      title: l.cameraSearchSources,
      trailing: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: _busy ? null : widget.onDone,
        child: Text(l.cameraSearchReturnToSearch),
      ),
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            footer: Text(l.cameraSearchSourceHelp),
            children: [
              if (_busy)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: CupertinoActivityIndicator()),
                ),
              if (_failed || _saved)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      _failed
                          ? l.cameraProfileSourcesFailed
                          : l.cameraProfileSourcesSaved,
                    ),
                  ),
                ),
              SettingsActionTile(
                title: Text(l.cameraProfileReconnect),
                leading: const Icon(CupertinoIcons.refresh),
                onTap: _busy ? null : _load,
              ),
              SettingsActionTile(
                title: Text(l.cameraSearchFrigateService),
                additionalInfo: Text(
                  _selected?.name ?? l.cameraProfileChooseSource,
                ),
                onTap: _busy || (_source?.services.isEmpty ?? true)
                    ? null
                    : _choose,
              ),
            ],
          ),
        ),
        if (_source != null)
          SliverToBoxAdapter(
            child: SettingsSection(
              header: Text(l.cameraSearchAllowedCameras),
              footer: Text(l.cameraSearchCameraHelp),
              children: [
                for (final camera in _source!.cameras)
                  SettingsActionTile(
                    title: Text(camera.name),
                    additionalInfo: Icon(
                      _cameras.contains(camera.id)
                          ? CupertinoIcons.check_mark_circled_solid
                          : CupertinoIcons.circle,
                    ),
                    onTap:
                        _busy ||
                            !_cameras.contains(camera.id) &&
                                _cameras.length >= 16
                        ? null
                        : () => setState(() {
                            if (!_cameras.remove(camera.id)) {
                              _cameras.add(camera.id);
                            }
                            _saved = false;
                          }),
                  ),
                if (_source!.cameras.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(l.cameraSearchNoSources),
                  ),
              ],
            ),
          ),
        SliverToBoxAdapter(
          child: SettingsSection(
            children: [
              SettingsActionTile(
                buttonKey: const ValueKey('camera-search-sources-save'),
                title: Text(l.cameraProfileSaveSources),
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
