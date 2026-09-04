import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../data/models/proxmox_guest.dart';
import '../data/models/proxmox_storage.dart';
import '../providers/proxmox_providers.dart';
import 'widgets/proxmox_guest_type_label.dart';

/// Template picker → target storage/new id/name → clone → poll the
/// resulting task until it finishes. Proxmox's own convention is that a
/// "template" is a VM/container clone source, so cloning an existing
/// template is the create-from-template mechanism (see `ProxmoxClient`).
class ProxmoxCreateGuestScreen extends ConsumerWidget {
  const ProxmoxCreateGuestScreen({super.key, required this.nodeName});

  final String nodeName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final guestsAsync = ref.watch(proxmoxGuestsProvider(nodeName));

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          AppLocalizations.of(context).proxmoxCreateFromTemplateTitle,
        ),
      ),
      child: SafeArea(
        child: guestsAsync.when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) => Center(
            child: Text(
              AppLocalizations.of(context).adminLoadError(error.toString()),
            ),
          ),
          data: (guests) {
            final templates = guests.where((g) => g.isTemplate).toList();
            if (templates.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    AppLocalizations.of(context).proxmoxNoTemplates,
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            return ListView(
              children: [
                const SizedBox(height: 16),
                CupertinoListSection.insetGrouped(
                  children: [
                    for (final template in templates)
                      CupertinoListTile(
                        title: Text(template.name),
                        subtitle: Text(
                          '${proxmoxGuestTypeLabel(context, template.type)} #${template.vmid}',
                        ),
                        trailing: const CupertinoListTileChevron(),
                        onTap: () => Navigator.of(context).push(
                          CupertinoPageRoute(
                            builder: (_) => _CloneFormScreen(
                              nodeName: nodeName,
                              template: template,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _CloneFormScreen extends ConsumerStatefulWidget {
  const _CloneFormScreen({required this.nodeName, required this.template});

  final String nodeName;
  final ProxmoxGuest template;

  @override
  ConsumerState<_CloneFormScreen> createState() => _CloneFormScreenState();
}

class _CloneFormScreenState extends ConsumerState<_CloneFormScreen> {
  final _idController = TextEditingController();
  late final _nameController = TextEditingController(
    text: '${widget.template.name}-clone',
  );
  bool _fullClone = true;
  ProxmoxStorage? _storage;
  bool _cloning = false;
  String? _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    _suggestId();
  }

  Future<void> _suggestId() async {
    try {
      final client = await ref.read(proxmoxClientProvider.future);
      final nextId = await client?.getNextGuestId();
      if (mounted && nextId != null && _idController.text.isEmpty) {
        _idController.text = '$nextId';
      }
    } catch (_) {
      // A user without cluster privileges can still enter an ID manually.
    }
  }

  @override
  void dispose() {
    _idController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickStorage(List<ProxmoxStorage> storages) async {
    final picked = await showCupertinoModalPopup<ProxmoxStorage>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(AppLocalizations.of(context).proxmoxTargetStorageTitle),
        actions: [
          for (final storage in storages)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, storage),
              child: Text(storage.name),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: Text(AppLocalizations.of(context).commonCancel),
        ),
      ),
    );
    if (picked != null && mounted) setState(() => _storage = picked);
  }

  Future<void> _submit() async {
    final client = ref.read(proxmoxClientProvider).value;
    final newId = int.tryParse(_idController.text.trim());
    if (client == null ||
        newId == null ||
        newId < 100 ||
        newId > 999999999 ||
        newId == widget.template.vmid) {
      setState(
        () => _error = AppLocalizations.of(context).proxmoxErrorInvalidId,
      );
      return;
    }

    setState(() {
      _cloning = true;
      _error = null;
      _status = AppLocalizations.of(context).proxmoxCloningStatus;
    });
    try {
      final upid = await client.cloneGuest(
        widget.nodeName,
        widget.template.type,
        widget.template.vmid,
        newId: newId,
        name: _nameController.text.trim().isEmpty
            ? null
            : _nameController.text.trim(),
        targetStorage: _fullClone ? _storage?.name : null,
        full: _fullClone,
      );

      final result = await client.waitForTask(
        widget.nodeName,
        upid,
        shouldContinue: () => mounted,
      );
      if (mounted && result != null) {
        ref.invalidate(proxmoxGuestsProvider(widget.nodeName));
        ref.invalidate(proxmoxTasksProvider(widget.nodeName));
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (!mounted) return;
      _status = null;
      setState(
        () =>
            _error = AppLocalizations.of(context)
                .proxmoxCloneFailed(e.toString()),
      );
    } finally {
      if (mounted) setState(() => _cloning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final storagesAsync = ref.watch(proxmoxStoragesProvider(widget.nodeName));

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          AppLocalizations.of(context).proxmoxCloneTitle(widget.template.name),
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            const SizedBox(height: 16),
            CupertinoListSection.insetGrouped(
              children: [
                CupertinoTextFormFieldRow(
                  controller: _idController,
                  readOnly: _cloning,
                  prefix: Text(AppLocalizations.of(context).proxmoxNewIdLabel),
                  keyboardType: TextInputType.number,
                ),
                CupertinoTextFormFieldRow(
                  controller: _nameController,
                  readOnly: _cloning,
                  prefix: Text(AppLocalizations.of(context).proxmoxFieldName),
                ),
                CupertinoListTile(
                  title: Text(AppLocalizations.of(context).proxmoxFullClone),
                  subtitle: Text(
                    AppLocalizations.of(context).proxmoxFullCloneHint,
                  ),
                  trailing: CupertinoSwitch(
                    value: _fullClone,
                    onChanged: _cloning
                        ? null
                        : (value) => setState(() => _fullClone = value),
                  ),
                ),
                storagesAsync.when(
                  loading: () => CupertinoListTile(
                    title: Text(
                      AppLocalizations.of(context).proxmoxStorageLabel,
                    ),
                    trailing: const CupertinoActivityIndicator(),
                  ),
                  error: (error, _) => CupertinoListTile(
                    title: Text(
                      AppLocalizations.of(context).proxmoxStorageLabel,
                    ),
                    subtitle: Text(
                      AppLocalizations.of(context)
                          .adminLoadError(error.toString()),
                    ),
                    trailing: CupertinoButton(
                      padding: EdgeInsets.zero,
                      onPressed: () => ref.invalidate(
                        proxmoxStoragesProvider(widget.nodeName),
                      ),
                      child: const Icon(CupertinoIcons.refresh),
                    ),
                  ),
                  data: (storages) {
                    final targetable = storages
                        .where((s) => s.supportsGuestType(widget.template.type))
                        .toList();
                    _storage ??= targetable.isEmpty ? null : targetable.first;
                    return CupertinoListTile(
                      title: Text(
                        AppLocalizations.of(context).proxmoxStorageLabel,
                      ),
                      additionalInfo: Text(
                        _storage?.name ??
                            AppLocalizations.of(context).commonNone,
                      ),
                      trailing: const CupertinoListTileChevron(),
                      onTap: !_fullClone || _cloning || targetable.isEmpty
                          ? null
                          : () => _pickStorage(targetable),
                    );
                  },
                ),
              ],
            ),
            if (_status != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(_status!, textAlign: TextAlign.center),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: CupertinoColors.systemRed.resolveFrom(context),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: CupertinoButton.filled(
                onPressed: _cloning ? null : _submit,
                child: _cloning
                    ? const CupertinoActivityIndicator(
                        color: CupertinoColors.white,
                      )
                    : Text(AppLocalizations.of(context).commonCreate),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
