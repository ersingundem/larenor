import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/proxmox_guest.dart';
import '../data/models/proxmox_storage.dart';
import '../providers/proxmox_providers.dart';
import 'proxmox_backups_screen.dart';
import 'proxmox_create_guest_screen.dart';
import 'widgets/proxmox_guest_row.dart';
import 'widgets/proxmox_usage_bar.dart';

class ProxmoxNodeDetailScreen extends ConsumerWidget {
  const ProxmoxNodeDetailScreen({super.key, required this.nodeName});

  final String nodeName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final guestsAsync = ref.watch(proxmoxGuestsProvider(nodeName));
    final storagesAsync = ref.watch(proxmoxStoragesProvider(nodeName));

    void refresh() {
      ref.invalidate(proxmoxGuestsProvider(nodeName));
      ref.invalidate(proxmoxStoragesProvider(nodeName));
    }

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(nodeName),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.of(context).push(
            CupertinoPageRoute(
              builder: (_) => ProxmoxCreateGuestScreen(nodeName: nodeName),
            ),
          ),
          child: const Icon(CupertinoIcons.add),
        ),
      ),
      child: SafeArea(
        child: guestsAsync.when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) => Center(child: Text('Failed to load: $error')),
          data: (guests) {
            final vms = guests.where((g) => g.type == ProxmoxGuestType.qemu);
            final containers = guests.where(
              (g) => g.type == ProxmoxGuestType.lxc,
            );
            return ListView(
              children: [
                const SizedBox(height: 16),
                if (vms.isNotEmpty)
                  CupertinoListSection.insetGrouped(
                    header: const Text('VIRTUAL MACHINES'),
                    children: [
                      for (final guest in vms)
                        ProxmoxGuestRow(guest: guest, onChanged: refresh),
                    ],
                  ),
                if (containers.isNotEmpty)
                  CupertinoListSection.insetGrouped(
                    header: const Text('CONTAINERS'),
                    children: [
                      for (final guest in containers)
                        ProxmoxGuestRow(guest: guest, onChanged: refresh),
                    ],
                  ),
                storagesAsync.when(
                  loading: () => const SizedBox.shrink(),
                  error: (_, _) => const SizedBox.shrink(),
                  data: (storages) => storages.isEmpty
                      ? const SizedBox.shrink()
                      : CupertinoListSection.insetGrouped(
                          header: const Text('STORAGE'),
                          children: [
                            for (final storage in storages)
                              _StorageRow(nodeName: nodeName, storage: storage),
                          ],
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _StorageRow extends StatelessWidget {
  const _StorageRow({required this.nodeName, required this.storage});

  final String nodeName;
  final ProxmoxStorage storage;

  @override
  Widget build(BuildContext context) {
    return CupertinoListTile(
      title: Text(storage.name),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: ProxmoxUsageBar(
          label: storage.type,
          fraction: storage.usedFraction,
        ),
      ),
      trailing: storage.supportsBackups
          ? const CupertinoListTileChevron()
          : null,
      onTap: storage.supportsBackups
          ? () => Navigator.of(context).push(
              CupertinoPageRoute(
                builder: (_) => ProxmoxBackupsScreen(
                  nodeName: nodeName,
                  storageName: storage.name,
                ),
              ),
            )
          : null,
    );
  }
}
