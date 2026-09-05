import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../data/models/proxmox_backup.dart';
import '../data/models/proxmox_guest.dart';
import '../providers/proxmox_providers.dart';
import 'widgets/proxmox_guest_type_label.dart';
import 'proxmox_session_guard.dart';
import 'proxmox_mutation_support.dart';

class ProxmoxBackupsScreen extends ConsumerStatefulWidget {
  const ProxmoxBackupsScreen({
    super.key,
    required this.nodeName,
    required this.storageName,
    this.sourceCurrent,
  });

  final String nodeName;
  final String storageName;
  final bool Function()? sourceCurrent;

  @override
  ConsumerState<ProxmoxBackupsScreen> createState() =>
      _ProxmoxBackupsScreenState();
}

class _ProxmoxBackupsScreenState
    extends ProxmoxSessionState<ProxmoxBackupsScreen> {
  @override
  bool sourceSessionCurrent() => widget.sourceCurrent?.call() ?? true;
  bool get _available =>
      sessionAvailable && widget.sourceCurrent?.call() != false;
  bool _current(ProxmoxSessionLease lease) =>
      _available && isSessionCurrent(lease);
  bool _backingUp = false;
  bool _needsReview = false;
  bool _sent = false;
  String? _message;
  Route<dynamic>? _modal;

  @override
  void onSessionInvalidated() {
    final route = _modal;
    _modal = null;
    if (route?.isActive == true) route!.navigator?.removeRoute(route);
    if (_sent) _needsReview = true;
  }

  @override
  void didUpdateWidget(ProxmoxBackupsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nodeName != widget.nodeName ||
        oldWidget.storageName != widget.storageName) {
      sessionGeneration++;
      onSessionInvalidated();
    }
  }

  Future<void> _backUpNow(
    ProxmoxSessionLease lease,
    List<ProxmoxGuest> guests,
  ) async {
    if (_backingUp || _needsReview || !_current(lease)) return;
    final node = widget.nodeName;
    final storage = widget.storageName;
    final l10n = AppLocalizations.of(context);
    setState(() {
      _backingUp = true;
      _message = null;
    });
    var accepted = false;
    var sent = false;
    try {
      final route = CupertinoModalPopupRoute<ProxmoxGuest>(
        builder: (context) => CupertinoActionSheet(
          title: Text('${l10n.proxmoxBackUpNowTitle} · $storage'),
          actions: [
            for (final guest in guests.where(
              (item) => item.node == node && !item.isTemplate,
            ))
              CupertinoActionSheetAction(
                onPressed: () => closeProxmoxModal(context, guest),
                child: Text(
                  '${proxmoxGuestTypeLabel(context, guest.type)} #${guest.vmid}: ${guest.name}',
                ),
              ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => closeProxmoxModal(context),
            child: Text(l10n.commonCancel),
          ),
        ),
      );
      _modal = route;
      final guest = await Navigator.of(context).push<ProxmoxGuest>(route);
      if (identical(_modal, route)) _modal = null;
      if (guest == null || !_current(lease)) return;
      final latest = ref.read(proxmoxGuestsProvider(node));
      if (latest.isLoading ||
          latest.hasError ||
          latest.value?.any(
                (item) => sameProxmoxGuest(item, guest) && !item.isTemplate,
              ) !=
              true) {
        return;
      }
      sent = true;
      setState(() => _sent = true);
      final upid = await lease.client.triggerBackup(
        node,
        vmid: guest.vmid,
        storage: storage,
      );
      accepted = true;
      if (!_current(lease)) {
        _needsReview = true;
        return;
      }
      setState(() => _message = l10n.actionAccepted);
      final result = await lease.client.waitForTask(
        node,
        upid,
        shouldContinue: () => _current(lease),
      );
      if (!_current(lease)) {
        _needsReview = true;
        return;
      }
      if (result?.isSuccess != true) {
        setState(() {
          _needsReview = true;
          _message = l10n.proxmoxActionUnknown;
        });
        return;
      }
      ref.invalidate(proxmoxBackupsProvider(node, storage));
      ref.invalidate(proxmoxStoragesProvider(node));
      ref.invalidate(proxmoxTasksProvider(node));
      setState(() => _message = l10n.proxmoxTaskSucceeded);
    } catch (error) {
      if (sent && (accepted || proxmoxMutationMayHaveRun(error))) {
        _needsReview = true;
      }
      if (_current(lease)) {
        setState(
          () => _message = proxmoxMutationFailureLabel(
            l10n,
            error,
            accepted: accepted,
          ),
        );
      }
    } finally {
      _sent = false;
      if (mounted) setState(() => _backingUp = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    watchProxmoxSession();
    final backupsAsync = _available
        ? ref.watch(proxmoxBackupsProvider(widget.nodeName, widget.storageName))
        : null;
    final guestsAsync = _available
        ? ref.watch(proxmoxGuestsProvider(widget.nodeName))
        : null;
    final lease = captureSession();
    final guests =
        guestsAsync == null || guestsAsync.isLoading || guestsAsync.hasError
        ? null
        : guestsAsync.value;

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(widget.storageName),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed:
              _backingUp ||
                  _needsReview ||
                  lease == null ||
                  guests?.isNotEmpty != true
              ? null
              : () => _backUpNow(lease, guests!),
          child: _sent
              ? const CupertinoActivityIndicator()
              : const Icon(CupertinoIcons.add),
        ),
      ),
      child: SafeArea(
        child: !_available
            ? Center(
                child: Text(AppLocalizations.of(context).proxmoxSessionExpired),
              )
            : Column(
                children: [
                  if (_message != null || _needsReview)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        _needsReview
                            ? AppLocalizations.of(context).proxmoxActionUnknown
                            : _message!,
                      ),
                    ),
                  Expanded(
                    child: backupsAsync!.when(
                      skipLoadingOnRefresh: false,
                      skipLoadingOnReload: false,
                      skipError: false,
                      loading: () =>
                          const Center(child: CupertinoActivityIndicator()),
                      error: (error, _) => Center(
                        child: Text(
                          AppLocalizations.of(context).healthReadError,
                        ),
                      ),
                      data: (backups) {
                        if (backups.isEmpty) {
                          return Center(
                            child: Text(
                              AppLocalizations.of(context).proxmoxNoBackups,
                            ),
                          );
                        }
                        return ListView(
                          children: [
                            const SizedBox(height: 16),
                            CupertinoListSection.insetGrouped(
                              children: [
                                for (final backup in backups)
                                  _BackupRow(backup: backup),
                              ],
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
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
