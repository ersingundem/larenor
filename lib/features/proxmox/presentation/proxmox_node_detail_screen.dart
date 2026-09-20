import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../data/models/proxmox_guest.dart';
import '../data/models/proxmox_storage.dart';
import '../providers/proxmox_providers.dart';
import 'proxmox_backups_screen.dart';
import 'proxmox_create_guest_screen.dart';
import 'proxmox_tasks_screen.dart';
import 'proxmox_session_guard.dart';
import 'widgets/proxmox_guest_row.dart';
import 'widgets/proxmox_usage_bar.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';

class ProxmoxNodeDetailScreen extends ConsumerStatefulWidget {
  const ProxmoxNodeDetailScreen({
    super.key,
    required this.nodeName,
    this.sourceCurrent,
  });

  final String nodeName;
  final bool Function()? sourceCurrent;

  @override
  ConsumerState<ProxmoxNodeDetailScreen> createState() =>
      _ProxmoxNodeDetailScreenState();
}

class _ProxmoxNodeDetailScreenState
    extends ProxmoxSessionState<ProxmoxNodeDetailScreen> {
  String get nodeName => widget.nodeName;
  @override
  bool sourceSessionCurrent() => widget.sourceCurrent?.call() ?? true;

  @override
  Widget build(BuildContext context) {
    watchProxmoxSession();
    if (!sessionAvailable) {
      return AppPageScaffold(
        navigationBar: CupertinoNavigationBar(middle: Text(nodeName)),
        child: SafeArea(
          child: Center(
            child: Text(AppLocalizations.of(context).proxmoxSessionExpired),
          ),
        ),
      );
    }
    final generation = sessionGeneration;
    bool current() =>
        mounted &&
        sessionAvailable &&
        generation == sessionGeneration &&
        ModalRoute.of(context)?.isCurrent != false;
    void open(Widget page) {
      if (!current()) return;
      Navigator.of(context)
          .push(CupertinoPageRoute<void>(builder: (_) => page));
    }

    final guestsAsync = ref.watch(proxmoxGuestsProvider(nodeName));
    final storagesAsync = ref.watch(proxmoxStoragesProvider(nodeName));

    void refresh() {
      if (!current()) return;
      ref.invalidate(proxmoxGuestsProvider(nodeName));
      ref.invalidate(proxmoxStoragesProvider(nodeName));
    }

    final l10n = AppLocalizations.of(context);
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(nodeName)),
      child: SafeArea(
        child: guestsAsync.when(
          skipLoadingOnRefresh: false,
          skipLoadingOnReload: false,
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) =>
              Center(child: Text(AppLocalizations.of(context).commonError)),
          data: (guests) {
            final vms = guests.where((g) => g.type == ProxmoxGuestType.qemu);
            final containers = guests.where(
              (g) => g.type == ProxmoxGuestType.lxc,
            );
            return ListView(
              children: [
                const SizedBox(height: 16),
                SettingsSection(
                  children: [
                    SettingsActionTile(
                      buttonKey: const ValueKey('proxmox-node-refresh'),
                      leading: const Icon(CupertinoIcons.refresh),
                      title: Text(l10n.commonRefresh),
                      onTap: refresh,
                    ),
                    SettingsActionTile(
                      buttonKey: const ValueKey('proxmox-node-add'),
                      leading: const Icon(CupertinoIcons.add),
                      title: Text(l10n.proxmoxCreateFromTemplateTitle),
                      onTap: () => open(
                        ProxmoxCreateGuestScreen(
                          nodeName: nodeName,
                          sourceCurrent: captureProxmoxRouteSource(ref),
                        ),
                      ),
                    ),
                    SettingsActionTile(
                      buttonKey: const ValueKey('proxmox-node-tasks'),
                      leading: const Icon(CupertinoIcons.clock),
                      title: Text(l10n.proxmoxTasksTitle),
                      onTap: () => open(
                        ProxmoxTasksScreen(
                          nodeName: nodeName,
                          sourceCurrent: captureProxmoxRouteSource(ref),
                        ),
                      ),
                    ),
                  ],
                ),
                if (vms.isNotEmpty)
                  SettingsSection(
                    header: Text(AppLocalizations.of(context).proxmoxVmsHeader),
                    children: [
                      for (final guest in vms)
                        ProxmoxGuestRow(
                          key: ValueKey('${guest.type.name}-${guest.vmid}'),
                          guest: guest,
                          onChanged: refresh,
                        ),
                    ],
                  ),
                if (containers.isNotEmpty)
                  SettingsSection(
                    header: Text(
                      AppLocalizations.of(context).proxmoxContainersHeader,
                    ),
                    children: [
                      for (final guest in containers)
                        ProxmoxGuestRow(
                          key: ValueKey('${guest.type.name}-${guest.vmid}'),
                          guest: guest,
                          onChanged: refresh,
                        ),
                    ],
                  ),
                storagesAsync.when(
                  skipLoadingOnRefresh: false,
                  skipLoadingOnReload: false,
                  loading: () => const SizedBox.shrink(),
                  error: (error, _) => Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(AppLocalizations.of(context).commonError),
                  ),
                  data: (storages) => storages.isEmpty
                      ? const SizedBox.shrink()
                      : SettingsSection(
                          header: Text(
                            AppLocalizations.of(context).proxmoxStorageHeader,
                          ),
                          children: [
                            for (final storage in storages)
                              _StorageRow(
                                storage: storage,
                                onOpen: () => open(
                                  ProxmoxBackupsScreen(
                                    nodeName: nodeName,
                                    storageName: storage.name,
                                    sourceCurrent: captureProxmoxRouteSource(
                                      ref,
                                    ),
                                  ),
                                ),
                              ),
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
  const _StorageRow({required this.onOpen, required this.storage});

  final VoidCallback onOpen;
  final ProxmoxStorage storage;

  @override
  Widget build(BuildContext context) {
    if (!storage.supportsBackups) {
      return CupertinoListTile(
        leading: const Icon(CupertinoIcons.archivebox),
        title: Text(storage.name),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: ProxmoxUsageBar(
            label: storage.type,
            fraction: storage.usedFraction,
          ),
        ),
      );
    }
    return SettingsActionTile(
      buttonKey: ValueKey('proxmox-storage-${storage.name}'),
      leading: const Icon(CupertinoIcons.archivebox),
      title: Text(storage.name),
      additionalInfo: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: ProxmoxUsageBar(
          label: storage.type,
          fraction: storage.usedFraction,
        ),
      ),
      onTap: onOpen,
    );
  }
}
