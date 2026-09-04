import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../data/models/proxmox_guest.dart';
import '../../providers/proxmox_providers.dart';
import '../proxmox_guest_detail_screen.dart';
import 'proxmox_guest_type_label.dart';

/// Shared row for both VM and container lists — a status-aware
/// power-action sheet (only actions valid for the guest's current state
/// are shown) plus navigation into the guest detail screen.
class ProxmoxGuestRow extends ConsumerStatefulWidget {
  const ProxmoxGuestRow({
    super.key,
    required this.guest,
    required this.onChanged,
  });

  final ProxmoxGuest guest;
  final VoidCallback onChanged;

  @override
  ConsumerState<ProxmoxGuestRow> createState() => _ProxmoxGuestRowState();
}

class _ProxmoxGuestRowState extends ConsumerState<ProxmoxGuestRow> {
  bool _busy = false;
  ProxmoxGuest get guest => widget.guest;

  @override
  Widget build(BuildContext context) {
    return CupertinoListTile(
      leading: Icon(
        guest.isRunning
            ? CupertinoIcons.play_circle_fill
            : CupertinoIcons.stop_circle,
        color: guest.isRunning
            ? CupertinoColors.systemGreen.resolveFrom(context)
            : CupertinoColors.systemGrey,
      ),
      title: Text(
        guest.isTemplate
            ? AppLocalizations.of(context).proxmoxTemplateName(guest.name)
            : guest.name,
      ),
      subtitle: Text(
        '${proxmoxGuestTypeLabel(context, guest.type)} #${guest.vmid} · '
        '${_statusLabel(context, guest.status)}',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (guest.powerActions.isNotEmpty)
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              onPressed: _busy ? null : () => _showActions(context),
              child: _busy
                  ? const CupertinoActivityIndicator(radius: 10)
                  : const Icon(CupertinoIcons.power, size: 20),
            ),
          const SizedBox(width: 4),
          const CupertinoListTileChevron(),
        ],
      ),
      onTap: () => Navigator.of(context).push(
        CupertinoPageRoute(
          builder: (_) => ProxmoxGuestDetailScreen(guest: guest),
        ),
      ),
    );
  }

  Future<void> _showActions(BuildContext context) async {
    final client = ref.read(proxmoxClientProvider).value;
    if (client == null) return;

    final actions = guest.powerActions;
    if (actions.isEmpty) return;

    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(guest.name),
        actions: [
          for (final a in actions)
            CupertinoActionSheetAction(
              isDestructiveAction: a == 'stop',
              onPressed: () => Navigator.pop(context, a),
              child: Text(_label(context, a)),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: Text(AppLocalizations.of(context).commonCancel),
        ),
      ),
    );

    if (action == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final upid = await client.powerAction(
        guest.node,
        guest.type,
        guest.vmid,
        action,
      );
      final result = await client.waitForTask(
        guest.node,
        upid,
        shouldContinue: () => mounted,
      );
      if (result != null && mounted) widget.onChanged();
    } catch (error) {
      if (!context.mounted) return;
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
      if (mounted) {
        ref.invalidate(proxmoxTasksProvider(guest.node));
        setState(() => _busy = false);
      }
    }
  }

  String _statusLabel(BuildContext context, String status) {
    final l10n = AppLocalizations.of(context);
    return switch (status) {
      'running' => l10n.proxmoxStatusRunning,
      'stopped' => l10n.proxmoxStatusStopped,
      'paused' => l10n.proxmoxStatusPaused,
      'suspended' => l10n.proxmoxStatusSuspended,
      _ => status,
    };
  }

  String _label(BuildContext context, String action) {
    final l10n = AppLocalizations.of(context);
    return switch (action) {
      'start' => l10n.proxmoxActionStart,
      'shutdown' => l10n.proxmoxActionShutdown,
      'stop' => l10n.proxmoxActionForceStop,
      'reboot' => l10n.proxmoxActionReboot,
      'suspend' => l10n.proxmoxActionSuspend,
      'resume' => l10n.proxmoxActionResume,
      _ => action,
    };
  }
}
