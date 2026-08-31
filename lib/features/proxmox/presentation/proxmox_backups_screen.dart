import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/proxmox_backup.dart';
import '../data/models/proxmox_guest.dart';
import '../providers/proxmox_providers.dart';

class ProxmoxBackupsScreen extends ConsumerStatefulWidget {
  const ProxmoxBackupsScreen({
    super.key,
    required this.nodeName,
    required this.storageName,
  });

  final String nodeName;
  final String storageName;

  @override
  ConsumerState<ProxmoxBackupsScreen> createState() =>
      _ProxmoxBackupsScreenState();
}

class _ProxmoxBackupsScreenState extends ConsumerState<ProxmoxBackupsScreen> {
  bool _backingUp = false;

  Future<void> _backUpNow(List<ProxmoxGuest> guests) async {
    final guest = await showCupertinoModalPopup<ProxmoxGuest>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: const Text('Back Up Now'),
        actions: [
          for (final guest in guests)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, guest),
              child: Text('${guest.type.label}: ${guest.name}'),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ),
    );
    if (guest == null) return;

    final client = ref.read(proxmoxClientProvider).value;
    if (client == null) return;

    setState(() => _backingUp = true);
    try {
      final upid = await client.triggerBackup(
        widget.nodeName,
        vmid: guest.vmid,
        storage: widget.storageName,
      );
      while (mounted) {
        final poll = await client.getTaskStatus(widget.nodeName, upid);
        if (!poll.isRunning) break;
        await Future.delayed(const Duration(seconds: 2));
      }
      ref.invalidate(
        proxmoxBackupsProvider(widget.nodeName, widget.storageName),
      );
    } finally {
      if (mounted) setState(() => _backingUp = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final backupsAsync = ref.watch(
      proxmoxBackupsProvider(widget.nodeName, widget.storageName),
    );
    final guestsAsync = ref.watch(proxmoxGuestsProvider(widget.nodeName));

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(widget.storageName),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _backingUp || guestsAsync.value == null
              ? null
              : () => _backUpNow(guestsAsync.value!),
          child: _backingUp
              ? const CupertinoActivityIndicator()
              : const Icon(CupertinoIcons.add),
        ),
      ),
      child: SafeArea(
        child: backupsAsync.when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) => Center(child: Text('Failed to load: $error')),
          data: (backups) {
            if (backups.isEmpty) {
              return const Center(child: Text('No backups on this storage'));
            }
            return ListView(
              children: [
                const SizedBox(height: 16),
                CupertinoListSection.insetGrouped(
                  children: [
                    for (final backup in backups) _BackupRow(backup: backup),
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

class _BackupRow extends StatelessWidget {
  const _BackupRow({required this.backup});

  final ProxmoxBackup backup;

  @override
  Widget build(BuildContext context) {
    return CupertinoListTile(
      leading: const Icon(CupertinoIcons.archivebox),
      title: Text(
        backup.vmid != null ? 'VM/CT #${backup.vmid}' : backup.volumeId,
      ),
      subtitle: Text(
        [
          if (backup.createdAt != null) backup.createdAt!.toLocal().toString(),
          if (backup.sizeBytes != null) _formatBytes(backup.sizeBytes!),
        ].join(' · '),
      ),
    );
  }

  String _formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex++;
    }
    return '${value.toStringAsFixed(1)} ${units[unitIndex]}';
  }
}
