import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/direct_home_access.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../auth/providers/auth_providers.dart';
import '../../dashboard/presentation/entity_picker_screen.dart';
import '../../ha_client/data/models/ha_entity.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../../health/data/health_configuration.dart';
import '../domain/door_station.dart';
import '../providers/intercom_providers.dart';

/// Configuration is reachable only through the existing Settings PIN gate.
class IntercomSettingsScreen extends ConsumerWidget {
  const IntercomSettingsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final stations = ref.watch(doorStationsProvider);
    final config = ref.watch(connectionConfigProvider);
    void edit([DoorStation? station]) => Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => _StationEditor(initial: station),
      ),
    );
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(l10n.intercomTitle)),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(l10n.intercomSetupDescription),
            const SizedBox(height: 16),
            stations.when(
              loading: () => const Center(child: CupertinoActivityIndicator()),
              error: (_, _) => CupertinoButton(
                onPressed: () => ref.invalidate(doorStationsProvider),
                child: Text(l10n.commonRetry),
              ),
              data: (values) => SettingsSection(
                children: [
                  for (final station in values)
                    CupertinoListTile(
                      title: Text(station.name),
                      subtitle: Text(
                        station.unlockEnabled
                            ? l10n.intercomReleaseEnabled
                            : l10n.intercomReleaseDisabled,
                      ),
                      trailing: const CupertinoListTileChevron(),
                      onTap: () => edit(station),
                    ),
                  if (values.length < DoorStation.maxStations)
                    CupertinoListTile(
                      title: Text(l10n.intercomAdd),
                      leading: const Icon(CupertinoIcons.add_circled),
                      onTap: config.value == null || config.isReloading
                          ? null
                          : () => edit(),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StationEditor extends ConsumerStatefulWidget {
  const _StationEditor({this.initial});
  final DoorStation? initial;
  @override
  ConsumerState<_StationEditor> createState() => _StationEditorState();
}

class _StationEditorState extends ConsumerState<_StationEditor> {
  late final _homeAccess = ref.read(directHomeAccessProvider);
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _connection = ref.read(connectionConfigProvider).value;
  late String? _camera = widget.initial?.cameraEntityId;
  late String? _chime = widget.initial?.chimeEntityId;
  late String? _activeCall = widget.initial?.callActiveEntityId;
  late String? _contact = widget.initial?.doorContactEntityId;
  late String? _unlock = widget.initial?.unlockEntityId;
  late bool _requiresCall = widget.initial?.requiresActiveCall ?? true;
  late bool _enabled =
      widget.initial?.serverUrl == _connection?.baseUrl &&
      (widget.initial?.unlockEnabled ?? false);
  bool _busy = false;
  bool _failed = false;

  bool get _sameConnection =>
      mounted &&
      _homeAccess.isCurrent &&
      sameHealthConfiguration(
        _connection,
        ref.read(connectionConfigProvider).value,
      );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pick(
    Set<String> domains,
    void Function(String?) setValue,
  ) async {
    if (_busy || !_sameConnection) return;
    final states = ref.read(entitiesProvider);
    if (states.isReloading) return;
    final entity = await Navigator.of(context).push<HaEntity>(
      CupertinoPageRoute(
        builder: (_) => EntityPickerScreen(
          entities: (states.value?.values ?? const <HaEntity>[])
              .where((e) => domains.contains(e.domain))
              .toList(),
        ),
      ),
    );
    if (entity != null && mounted && _sameConnection) {
      setState(() {
        setValue(entity.entityId);
        _enabled = false;
      });
    }
  }

  Future<void> _save({bool remove = false}) async {
    if (_busy || !_sameConnection || _connection == null) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final store = ref.read(doorStationStoreProvider);
      if (!mounted || !_sameConnection) return;
      final station = remove
          ? widget.initial!
          : DoorStation.fromJson(
              DoorStation(
                id:
                    widget.initial?.id ??
                    DateTime.now().microsecondsSinceEpoch.toString(),
                name: _name.text.trim(),
                serverUrl: _connection.baseUrl,
                cameraEntityId: _camera,
                chimeEntityId: _chime,
                callActiveEntityId: _activeCall,
                doorContactEntityId: _contact,
                unlockEntityId: _unlock,
                requiresActiveCall: _requiresCall,
                unlockEnabled: _enabled,
              ).toJson(),
            );
      if (remove) {
        await store.remove(
          station.id,
          isCurrent: () => mounted && _sameConnection,
        );
      } else {
        await store.upsert(
          station,
          isCurrent: () => mounted && _sameConnection,
        );
      }
      if (!mounted) return;
      ref.invalidate(doorStationsProvider);
      Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    ref.watch(directHomeAccessProvider);
    final states = ref.watch(entitiesProvider);
    final connection = ref.watch(connectionConfigProvider);
    final changed = connection.isReloading || !_sameConnection;
    Widget field(
      String label,
      String? value,
      Set<String> domains,
      void Function(String?) setValue,
    ) => CupertinoListTile(
      title: Text(label),
      subtitle: Text(
        value == null
            ? l10n.intercomNotSelected
            : states.value?[value]?.friendlyName ?? value,
      ),
      trailing: value == null
          ? const CupertinoListTileChevron()
          : CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: _busy || changed
                  ? null
                  : () => setState(() {
                      setValue(null);
                      _enabled = false;
                    }),
              child: Icon(
                CupertinoIcons.clear_circled,
                semanticLabel: l10n.intercomClearSelection,
              ),
            ),
      onTap: _busy || changed ? null : () => _pick(domains, setValue),
    );
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(l10n.intercomSetup)),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            CupertinoTextField(
              controller: _name,
              placeholder: l10n.intercomName,
              maxLength: 80,
              enabled: !_busy && !changed,
            ),
            const SizedBox(height: 16),
            SettingsSection(
              children: [
                field(l10n.intercomCamera, _camera, {
                  'camera',
                }, (v) => _camera = v),
                field(l10n.intercomChime, _chime, {
                  'binary_sensor',
                }, (v) => _chime = v),
                field(l10n.intercomActiveCall, _activeCall, {
                  'binary_sensor',
                }, (v) => _activeCall = v),
                field(l10n.intercomDoorContact, _contact, {
                  'binary_sensor',
                }, (v) => _contact = v),
                field(l10n.intercomReleaseControl, _unlock, {
                  'button',
                  'lock',
                }, (v) => _unlock = v),
              ],
            ),
            SettingsSection(
              children: [
                CupertinoListTile(
                  title: Text(l10n.intercomRequireCall),
                  trailing: CupertinoSwitch(
                    value: _requiresCall,
                    onChanged: _busy || changed
                        ? null
                        : (value) => setState(() {
                            _requiresCall = value;
                            _enabled = false;
                          }),
                  ),
                ),
                CupertinoListTile(
                  title: Text(l10n.intercomReleaseEnabled),
                  trailing: CupertinoSwitch(
                    value: _enabled,
                    onChanged:
                        _busy ||
                            changed ||
                            _unlock == null ||
                            (_requiresCall && _activeCall == null)
                        ? null
                        : (value) => setState(() => _enabled = value),
                  ),
                ),
              ],
            ),
            Text(l10n.intercomCommissioningNote),
            if (changed) Text(l10n.intercomDifferentServer),
            if (_failed)
              Text(
                l10n.intercomSaveError,
                style: TextStyle(
                  color: CupertinoColors.systemRed.resolveFrom(context),
                ),
              ),
            const SizedBox(height: 16),
            CupertinoButton.filled(
              onPressed: _busy || changed ? null : _save,
              child: _busy
                  ? const CupertinoActivityIndicator()
                  : Text(l10n.commonSave),
            ),
            if (widget.initial != null)
              CupertinoButton(
                onPressed: _busy || changed
                    ? null
                    : () async {
                        final confirmed = await showCupertinoDialog<bool>(
                          context: context,
                          builder: (context) => CupertinoAlertDialog(
                            title: Text(l10n.intercomRemove),
                            content: Text(widget.initial!.name),
                            actions: [
                              CupertinoDialogAction(
                                onPressed: () => Navigator.pop(context, false),
                                child: Text(l10n.commonCancel),
                              ),
                              CupertinoDialogAction(
                                isDestructiveAction: true,
                                onPressed: () => Navigator.pop(context, true),
                                child: Text(l10n.commonDelete),
                              ),
                            ],
                          ),
                        );
                        if (confirmed == true && mounted) {
                          await _save(remove: true);
                        }
                      },
                child: Text(l10n.intercomRemove),
              ),
          ],
        ),
      ),
    );
  }
}
