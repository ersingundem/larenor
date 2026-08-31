import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/proxmox_guest.dart';
import '../../providers/proxmox_providers.dart';
import '../proxmox_guest_detail_screen.dart';

/// Shared row for both VM and container lists — a status-aware
/// power-action sheet (only actions valid for the guest's current state
/// are shown) plus navigation into the guest detail screen.
class ProxmoxGuestRow extends ConsumerWidget {
  const ProxmoxGuestRow({
    super.key,
    required this.guest,
    required this.onChanged,
  });

  final ProxmoxGuest guest;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CupertinoListTile(
      leading: Icon(
        guest.isRunning
            ? CupertinoIcons.play_circle_fill
            : CupertinoIcons.stop_circle,
        color: guest.isRunning
            ? CupertinoColors.systemGreen.resolveFrom(context)
            : CupertinoColors.systemGrey,
      ),
      title: Text(guest.isTemplate ? '${guest.name} (template)' : guest.name),
      subtitle: Text('${guest.type.label} #${guest.vmid} · ${guest.status}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CupertinoButton(
            padding: EdgeInsets.zero,
            minimumSize: Size.zero,
            onPressed: () => _showActions(context, ref),
            child: const Icon(CupertinoIcons.power, size: 20),
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

  Future<void> _showActions(BuildContext context, WidgetRef ref) async {
    final client = ref.read(proxmoxClientProvider).value;
    if (client == null) return;

    final actions = <String>[
      if (!guest.isRunning) 'start',
      if (guest.isRunning) 'shutdown',
      if (guest.isRunning) 'stop',
      if (guest.isRunning) 'reboot',
      if (guest.isRunning) 'suspend',
      if (guest.status == 'paused') 'resume',
    ];
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
              child: Text(_label(a)),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ),
    );

    if (action == null) return;
    await client.powerAction(guest.node, guest.type, guest.vmid, action);
    onChanged();
  }

  String _label(String action) => switch (action) {
    'start' => 'Start',
    'shutdown' => 'Shutdown',
    'stop' => 'Force Stop',
    'reboot' => 'Reboot',
    'suspend' => 'Suspend',
    'resume' => 'Resume',
    _ => action,
  };
}
