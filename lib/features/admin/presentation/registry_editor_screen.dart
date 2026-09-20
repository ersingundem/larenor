import 'package:flutter/cupertino.dart';

import '../../../shared/widgets/settings_section.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../media/hub/presentation/media_session_state.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../dashboard/providers/dashboard_providers.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../data/admin_client.dart';
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

class _RegistryEditorScreenState
    extends MediaSessionState<RegistryEditorScreen> {
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
  HaAdminClient? _scopeClient;
  late final int _scopeGeneration;
  bool _scopeExpired = false;

  @override
  void initState() {
    super.initState();
    _scopeClient = ref.read(haAdminClientProvider);
    _scopeGeneration = sessionGeneration;
  }

  bool _current() =>
      sessionCurrent(_scopeGeneration) &&
      !_scopeExpired &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent == true &&
      _scopeClient != null &&
      identical(_scopeClient, ref.read(haAdminClientProvider));

  @override
  void clearPendingInteraction() => _scopeExpired = true;

  @override
  void dispose() {
    _scopeExpired = true;
    _name.dispose();
    _icon.dispose();
    _entityId.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_current()) return;
    final client = _scopeClient!;
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
      if (!mounted || !_current()) return;
      var restart = false;
      if (device != null) {
        await client.updateDevice(device.id, changes);
        remoteSaved = true;
      } else {
        final result = await client.updateEntity(entity!.entityId, changes);
        remoteSaved = true;
        restart = result['require_restart'] == true;
        if (newId != null && _current()) {
          await ref
              .read(dashboardLayoutProvider.notifier)
              .renameEntityReferences(
                entity.entityId,
                newId,
                serverUrl: client.baseUrl,
                isCurrent: _current,
              );
        }
      }
      if (!mounted || !_current()) return;
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
      if (mounted && _current()) {
        Navigator.pop(context, changes['new_entity_id']);
      }
    } catch (_) {
      if (mounted && _current()) {
        if (remoteSaved) {
          ref.invalidate(devicesProvider);
          ref.invalidate(entityRegistryProvider);
          ref.invalidate(entitiesProvider);
          await showAdminMessage(
            context,
            AppLocalizations.of(
              context,
            ).adminLocalLayoutError(AppLocalizations.of(context).actionFailed),
          );
          if (mounted && _current()) Navigator.pop(context, newId);
        } else {
          setState(() => _error = AppLocalizations.of(context).actionFailed);
        }
      }
    } finally {
      layoutSubscription?.close();
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(haAdminClientProvider);
    ref.listen(haAdminClientProvider, (_, next) {
      if (!identical(_scopeClient, next) && !_scopeExpired) {
        setState(() => _scopeExpired = true);
      }
    });
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
        ),
        child: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: ListView(
                children: [
                  if (!_current())
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(l10n.adminEditorSessionChanged),
                    ),
                  SettingsSection(
                    footer: Text(l10n.adminRegistryHint),
                    children: [
                      ConstrainedBox(
                        key: const ValueKey('registry-editor-name'),
                        constraints: const BoxConstraints(minHeight: 48),
                        child: CupertinoTextFormFieldRow(
                          controller: _name,
                          prefix: Text(l10n.adminName),
                          readOnly: _saving || !_current(),
                          placeholder:
                              widget.device?.name ??
                              widget.entity?.originalName ??
                              '',
                        ),
                      ),
                      if (widget.entity != null) ...[
                        ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: CupertinoTextFormFieldRow(
                            controller: _entityId,
                            prefix: Text(l10n.adminEntityId),
                            readOnly: _saving || !_current(),
                            autocorrect: false,
                          ),
                        ),
                        ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: CupertinoTextFormFieldRow(
                            controller: _icon,
                            prefix: Text(l10n.adminIcon),
                            readOnly: _saving || !_current(),
                            placeholder: 'mdi:lightbulb',
                            autocorrect: false,
                          ),
                        ),
                      ],
                      ConstrainedBox(
                        key: const ValueKey('registry-editor-area'),
                        constraints: const BoxConstraints(minHeight: 48),
                        child: CupertinoListTile(
                          title: Text(l10n.adminArea),
                          subtitle: Text(
                            areaName ?? _area ?? l10n.commonNone,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: areas.isLoading
                              ? const CupertinoActivityIndicator()
                              : const CupertinoListTileChevron(),
                          onTap: _saving || areas.isLoading || !_current()
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
                                  if (picked != null && _current()) {
                                    setState(
                                      () => _area = picked.isEmpty
                                          ? null
                                          : picked,
                                    );
                                  }
                                },
                        ),
                      ),
                      ConstrainedBox(
                        key: const ValueKey('registry-editor-enabled'),
                        constraints: const BoxConstraints(minHeight: 48),
                        child: CupertinoListTile(
                          title: Text(l10n.adminEnabled),
                          trailing: CupertinoSwitch(
                            value: _enabled,
                            onChanged: _saving || !_current()
                                ? null
                                : (value) => setState(() => _enabled = value),
                          ),
                        ),
                      ),
                      if (widget.entity != null)
                        ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: CupertinoListTile(
                            title: Text(l10n.adminHidden),
                            trailing: CupertinoSwitch(
                              value: _hidden,
                              onChanged: _saving || !_current()
                                  ? null
                                  : (value) => setState(() => _hidden = value),
                            ),
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
                        style: const TextStyle(
                          color: CupertinoColors.systemRed,
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                    child: CupertinoButton.filled(
                      key: const ValueKey('registry-editor-save'),
                      minimumSize: const Size.fromHeight(48),
                      onPressed: _saving || !_current() ? null : _save,
                      child: _saving
                          ? const CupertinoActivityIndicator()
                          : Text(l10n.commonSave),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
