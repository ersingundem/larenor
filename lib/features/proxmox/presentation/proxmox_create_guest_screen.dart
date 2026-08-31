import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/proxmox_guest.dart';
import '../data/models/proxmox_storage.dart';
import '../providers/proxmox_providers.dart';

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
      navigationBar: const CupertinoNavigationBar(
        middle: Text('Create from Template'),
      ),
      child: SafeArea(
        child: guestsAsync.when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) => Center(child: Text('Failed to load: $error')),
          data: (guests) {
            final templates = guests.where((g) => g.isTemplate).toList();
            if (templates.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No templates on this node. Flag a VM or container as '
                    'a template in Proxmox first.',
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
                          '${template.type.label} #${template.vmid}',
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
  late final _idController = TextEditingController(
    text: '${widget.template.vmid + 100}',
  );
  late final _nameController = TextEditingController(
    text: '${widget.template.name}-clone',
  );
  bool _fullClone = true;
  ProxmoxStorage? _storage;
  bool _cloning = false;
  String? _status;
  String? _error;

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
        title: const Text('Target Storage'),
        actions: [
          for (final storage in storages)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, storage),
              child: Text(storage.name),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ),
    );
    if (picked != null) setState(() => _storage = picked);
  }

  Future<void> _submit() async {
    final client = ref.read(proxmoxClientProvider).value;
    final newId = int.tryParse(_idController.text.trim());
    if (client == null || newId == null) {
      setState(() => _error = 'Enter a valid numeric ID.');
      return;
    }

    setState(() {
      _cloning = true;
      _error = null;
      _status = 'Cloning…';
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
        targetStorage: _storage?.name,
        full: _fullClone,
      );

      while (mounted) {
        final poll = await client.getTaskStatus(widget.nodeName, upid);
        if (!poll.isRunning) {
          setState(() {
            _status = poll.isSuccess
                ? 'Done'
                : 'Failed: ${poll.exitStatus ?? 'unknown error'}';
          });
          if (poll.isSuccess) {
            ref.invalidate(proxmoxGuestsProvider(widget.nodeName));
            await Future.delayed(const Duration(seconds: 1));
            if (mounted) Navigator.of(context).pop();
          }
          break;
        }
        await Future.delayed(const Duration(seconds: 2));
      }
    } catch (e) {
      setState(() => _error = 'Clone failed: $e');
    } finally {
      if (mounted) setState(() => _cloning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final storagesAsync = ref.watch(proxmoxStoragesProvider(widget.nodeName));

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text('Clone ${widget.template.name}'),
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
                  prefix: const Text('New ID'),
                  keyboardType: TextInputType.number,
                ),
                CupertinoTextFormFieldRow(
                  controller: _nameController,
                  prefix: const Text('Name'),
                ),
                CupertinoListTile(
                  title: const Text('Full clone'),
                  subtitle: const Text('Off for a fast linked clone'),
                  trailing: CupertinoSwitch(
                    value: _fullClone,
                    onChanged: (value) => setState(() => _fullClone = value),
                  ),
                ),
                storagesAsync.when(
                  loading: () => const CupertinoListTile(
                    title: Text('Storage'),
                    trailing: CupertinoActivityIndicator(),
                  ),
                  error: (_, _) => const SizedBox.shrink(),
                  data: (storages) {
                    final targetable = storages
                        .where((s) => s.supportsTemplates)
                        .toList();
                    _storage ??= targetable.isEmpty ? null : targetable.first;
                    return CupertinoListTile(
                      title: const Text('Storage'),
                      additionalInfo: Text(_storage?.name ?? 'None'),
                      trailing: const CupertinoListTileChevron(),
                      onTap: targetable.isEmpty
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
                    : const Text('Create'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
