import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../data/models/proxmox_backup.dart';
import '../data/models/proxmox_guest.dart';
import '../providers/proxmox_providers.dart';
import 'widgets/proxmox_guest_type_label.dart';

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
        title: Text(AppLocalizations.of(context).proxmoxBackUpNowTitle),
        actions: [
          for (final guest in guests)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, guest),
              child: Text(
                '${proxmoxGuestTypeLabel(context, guest.type)}: ${guest.name}',
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: Text(AppLocalizations.of(context).commonCancel),
        ),
      ),
    );
    if (guest == null || !mounted) return;

    final client = ref.read(proxmoxClientProvider).value;
    if (client == null) return;

    setState(() => _backingUp = true);
    try {
      final upid = await client.triggerBackup(
        widget.nodeName,
        vmid: guest.vmid,
        storage: widget.storageName,
      );
      final result = await client.waitForTask(
        widget.nodeName,
        upid,
        shouldContinue: () => mounted,
      );
      if (!mounted || result == null) return;
      ref.invalidate(
        proxmoxBackupsProvider(widget.nodeName, widget.storageName),
      );
      ref.invalidate(proxmoxStoragesProvider(widget.nodeName));
      ref.invalidate(proxmoxTasksProvider(widget.nodeName));
    } catch (error) {
      if (!mounted) return;
      await showCupertinoDialog<void>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: Text(AppLocalizations.of(context).commonError),
          content: Text(error.toString()),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(context),
              child: Text(AppLocalizations.of(context).commonOk),
            ),
          ],
        ),
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
          onPressed: _backingUp || guestsAsync.value?.isNotEmpty != true
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
          error: (error, _) => Center(
            child: Text(
              AppLocalizations.of(context).adminLoadError(error.toString()),
            ),
          ),
          data: (backups) {
            if (backups.isEmpty) {
              return Center(
                child: Text(AppLocalizations.of(context).proxmoxNoBackups),
              );
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
        backup.vmid != null
            ? AppLocalizations.of(context).proxmoxVmCtId(backup.vmid!)
            : backup.volumeId,
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
