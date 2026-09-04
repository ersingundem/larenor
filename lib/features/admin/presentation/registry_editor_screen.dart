import 'package:flutter/cupertino.dart';

import '../../../shared/widgets/settings_section.dart';
import '../../../shared/widgets/app_page_scaffold.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../dashboard/providers/dashboard_providers.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../data/models/ha_device.dart';
import '../data/models/ha_registry_entry.dart';
import '../providers/admin_providers.dart';
import 'widgets/admin_dialogs.dart';

class RegistryEditorScreen extends ConsumerStatefulWidget {
  const RegistryEditorScreen.device(HaDevice value, {super.key})
    : device = value,
      entity = null;
  const RegistryEditorScreen.entity(HaRegistryEntry value, {super.key})
    : entity = value,
      device = null;

  final HaDevice? device;
  final HaRegistryEntry? entity;

  @override
  ConsumerState<RegistryEditorScreen> createState() =>
      _RegistryEditorScreenState();
}

class _RegistryEditorScreenState extends ConsumerState<RegistryEditorScreen> {
  late final _name = TextEditingController(
    text: widget.device?.nameByUser ?? widget.entity?.name ?? '',
  );
  late final _icon = TextEditingController(text: widget.entity?.icon ?? '');
  late final _entityId = TextEditingController(
    text: widget.entity?.entityId ?? '',
  );
  late String? _area = widget.device?.areaId ?? widget.entity?.areaId;
  late bool _enabled =
      (widget.device?.disabledBy ?? widget.entity?.disabledBy) == null;
  late bool _hidden = widget.entity?.hiddenBy != null;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _icon.dispose();
    _entityId.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final client = ref.read(haAdminClientProvider);
    if (client == null) return;
    final entity = widget.entity;
    final device = widget.device;
    final changes = <String, dynamic>{};
    final name = _name.text.trim();
    if (name != (device?.nameByUser ?? entity?.name ?? '')) {
      changes[device != null ? 'name_by_user' : 'name'] = name.isEmpty
          ? null
          : name;
    }
    if (_area != (device?.areaId ?? entity?.areaId)) changes['area_id'] = _area;
    if (_enabled != ((device?.disabledBy ?? entity?.disabledBy) == null)) {
      changes['disabled_by'] = _enabled ? null : 'user';
    }
    if (entity != null) {
      if (_hidden != (entity.hiddenBy != null)) {
        changes['hidden_by'] = _hidden ? 'user' : null;
      }
      final icon = _icon.text.trim();
      if (icon != (entity.icon ?? '')) {
        changes['icon'] = icon.isEmpty ? null : icon;
      }
      final newId = _entityId.text.trim();
      if (newId != entity.entityId) {
        if (!RegExp(r'^[a-z_]+\.[a-z0-9_]+$').hasMatch(newId) ||
            newId.split('.').first != entity.entityId.split('.').first) {
          setState(
            () => _error = AppLocalizations.of(context).adminInvalidValue,
          );
          return;
        }
        changes['new_entity_id'] = newId;
      }
    }
    if (changes.isEmpty) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    var remoteSaved = false;
    final newId = changes['new_entity_id'] as String?;
    final layoutSubscription = newId == null
        ? null
        : ref.listenManual(dashboardLayoutProvider, (_, _) {});
    try {
      if (newId != null) {
        await ref.read(dashboardLayoutProvider.future);
      }
      if (!mounted) return;
      var restart = false;
      if (device != null) {
        await client.updateDevice(device.id, changes);
        remoteSaved = true;
      } else {
        final result = await client.updateEntity(entity!.entityId, changes);
        remoteSaved = true;
        restart = result['require_restart'] == true;
        if (newId != null && mounted) {
          await ref
              .read(dashboardLayoutProvider.notifier)
              .renameEntityReferences(entity.entityId, newId);
        }
      }
      if (!mounted) return;
      ref.invalidate(devicesProvider);
      ref.invalidate(entityRegistryProvider);
      ref.invalidate(entitiesProvider);
      if (restart) {
        await showAdminMessage(
          context,
          AppLocalizations.of(context).adminRestartRequired,
          error: false,
        );
      }
      if (mounted) Navigator.pop(context, changes['new_entity_id']);
    } catch (error) {
      if (mounted) {
        if (remoteSaved) {
          ref.invalidate(devicesProvider);
          ref.invalidate(entityRegistryProvider);
          ref.invalidate(entitiesProvider);
          await showAdminMessage(
            context,
            AppLocalizations.of(context)
                .adminLocalLayoutError(error.toString()),
          );
          if (mounted) Navigator.pop(context, newId);
        } else {
          setState(() => _error = error.toString());
        }
      }
    } finally {
      layoutSubscription?.close();
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final areas = ref.watch(areasProvider);
    final values = areas.value ?? [];
    final areaName = values
        .where((item) => item.areaId == _area)
        .firstOrNull
        ?.name;
    return PopScope(
      canPop: !_saving,
      child: AppPageScaffold(
        navigationBar: CupertinoNavigationBar(
          middle: Text(
            widget.device != null ? l10n.adminEditDevice : l10n.adminEditEntity,
          ),
          trailing: CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: _saving ? null : _save,
            child: _saving
                ? const CupertinoActivityIndicator()
                : Text(l10n.commonSave),
          ),
        ),
        child: SafeArea(
          child: ListView(
            children: [
              SettingsSection(
                footer: Text(l10n.adminRegistryHint),
                children: [
                  CupertinoTextFormFieldRow(
                    controller: _name,
                    prefix: Text(l10n.adminName),
                    readOnly: _saving,
                    placeholder:
                        widget.device?.name ??
                        widget.entity?.originalName ??
                        '',
                  ),
                  if (widget.entity != null) ...[
                    CupertinoTextFormFieldRow(
                      controller: _entityId,
                      prefix: Text(l10n.adminEntityId),
                      readOnly: _saving,
                      autocorrect: false,
                    ),
                    CupertinoTextFormFieldRow(
                      controller: _icon,
                      prefix: Text(l10n.adminIcon),
                      readOnly: _saving,
                      placeholder: 'mdi:lightbulb',
                      autocorrect: false,
                    ),
                  ],
                  CupertinoListTile(
                    title: Text(l10n.adminArea),
                    additionalInfo: Text(areaName ?? _area ?? l10n.commonNone),
                    trailing: areas.isLoading
                        ? const CupertinoActivityIndicator()
                        : const CupertinoListTileChevron(),
                    onTap: _saving || areas.isLoading
                        ? null
                        : () async {
                            if (areas.hasError) {
                              ref.invalidate(areasProvider);
                              return;
                            }
                            final picked = await pickAdminArea(
                              context,
                              values,
                              _area,
                            );
                            if (picked != null && mounted) {
                              setState(
                                () => _area = picked.isEmpty ? null : picked,
                              );
                            }
                          },
                  ),
                  CupertinoListTile(
                    title: Text(l10n.adminEnabled),
                    trailing: CupertinoSwitch(
                      value: _enabled,
                      onChanged: _saving
                          ? null
                          : (value) => setState(() => _enabled = value),
                    ),
                  ),
                  if (widget.entity != null)
                    CupertinoListTile(
                      title: Text(l10n.adminHidden),
                      trailing: CupertinoSwitch(
                        value: _hidden,
                        onChanged: _saving
                            ? null
                            : (value) => setState(() => _hidden = value),
                      ),
                    ),
                ],
              ),
              if (areas.hasError)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(l10n.adminLoadError(areas.error.toString())),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: CupertinoColors.systemRed),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
