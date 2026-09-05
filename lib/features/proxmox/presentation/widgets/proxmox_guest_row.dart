import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../data/models/proxmox_guest.dart';
import '../../providers/proxmox_providers.dart';
import '../proxmox_guest_detail_screen.dart';
import 'proxmox_guest_type_label.dart';
import '../proxmox_session_guard.dart';
import '../proxmox_mutation_support.dart';

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

class _ProxmoxGuestRowState extends ProxmoxSessionState<ProxmoxGuestRow> {
  bool _busy = false;
  bool _sent = false;
  bool _needsReview = false;
  Route<dynamic>? _modal;

  @override
  void onSessionInvalidated() {
    final route = _modal;
    _modal = null;
    if (route?.isActive == true) route!.navigator?.removeRoute(route);
    if (_sent) _needsReview = true;
  }

  @override
  void didUpdateWidget(ProxmoxGuestRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!sameProxmoxGuest(oldWidget.guest, widget.guest)) {
      sessionGeneration++;
      onSessionInvalidated();
    }
  }

  ProxmoxGuest get guest => widget.guest;

  @override
  Widget build(BuildContext context) {
    watchProxmoxSession();
    if (sessionAvailable) ref.watch(proxmoxClientProvider);
    final lease = captureSession();
    final target = guest;
    if (!sessionAvailable) {
      return CupertinoListTile(
        title: Text(AppLocalizations.of(context).proxmoxSessionExpired),
      );
    }
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
        _needsReview
            ? AppLocalizations.of(context).proxmoxActionUnknown
            : '${proxmoxGuestTypeLabel(context, guest.type)} #${guest.vmid} · ${_statusLabel(context, guest.status)}',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (guest.powerActions.isNotEmpty)
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              onPressed: _busy || _needsReview || lease == null
                  ? null
                  : () => _showActions(lease, target),
              child: _sent
                  ? const CupertinoActivityIndicator(radius: 10)
                  : const Icon(CupertinoIcons.power, size: 20),
            ),
          const SizedBox(width: 4),
          const CupertinoListTileChevron(),
        ],
      ),
      onTap: _busy || lease == null ? null : () => _openDetails(lease, target),
    );
  }

  Future<void> _openDetails(
    ProxmoxSessionLease lease,
    ProxmoxGuest target,
  ) async {
    if (_busy || !isSessionCurrent(lease) || !sameProxmoxGuest(target, guest)) {
      return;
    }
    setState(() => _busy = true);
    final sourceCurrent = captureProxmoxRouteSource(ref);
    if (sourceCurrent == null) {
      setState(() => _busy = false);
      return;
    }
    try {
      await Navigator.of(context).push(
        CupertinoPageRoute(
          builder: (_) => ProxmoxGuestDetailScreen(
            guest: target,
            sourceCurrent: sourceCurrent,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showActions(
    ProxmoxSessionLease lease,
    ProxmoxGuest target,
  ) async {
    if (_busy ||
        _needsReview ||
        !isSessionCurrent(lease) ||
        !sameProxmoxGuest(target, guest)) {
      return;
    }
    final actions = List<String>.of(target.powerActions);
    if (actions.isEmpty) return;
    final l10n = AppLocalizations.of(context);
    setState(() => _busy = true);
    var accepted = false;
    try {
      final route = CupertinoModalPopupRoute<String>(
        builder: (context) => CupertinoActionSheet(
          title: Text('${target.name} · #${target.vmid}'),
          actions: [
            for (final action in actions)
              CupertinoActionSheetAction(
                isDestructiveAction: action == 'stop',
                onPressed: () => closeProxmoxModal(context, action),
                child: Text(_label(context, action)),
              ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => closeProxmoxModal(context),
            child: Text(l10n.commonCancel),
          ),
        ),
      );
      _modal = route;
      final action = await Navigator.of(context).push<String>(route);
      if (identical(_modal, route)) _modal = null;
      if (action == null ||
          !isSessionCurrent(lease) ||
          !sameProxmoxGuest(target, guest) ||
          !guest.powerActions.contains(action)) {
        return;
      }
      setState(() => _sent = true);
      final upid = await lease.client.powerAction(
        target.node,
        target.type,
        target.vmid,
        action,
      );
      accepted = true;
      if (!isSessionCurrent(lease)) {
        _needsReview = true;
        return;
      }
      final result = await lease.client.waitForTask(
        target.node,
        upid,
        shouldContinue: () =>
            isSessionCurrent(lease) && sameProxmoxGuest(target, guest),
      );
      if (!isSessionCurrent(lease) || !sameProxmoxGuest(target, guest)) {
        _needsReview = true;
        return;
      }
      if (result?.isSuccess == true) {
        widget.onChanged();
        ref.invalidate(proxmoxTasksProvider(target.node));
      } else {
        setState(() => _needsReview = true);
      }
    } catch (error) {
      if (_sent && (accepted || proxmoxMutationMayHaveRun(error))) {
        _needsReview = true;
      }
      if (mounted &&
          isSessionCurrent(lease) &&
          sameProxmoxGuest(target, guest)) {
        setState(() => _sent = false);
        final route = CupertinoDialogRoute<void>(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: Text(target.name),
            content: Text(
              proxmoxMutationFailureLabel(l10n, error, accepted: accepted),
            ),
            actions: [
              CupertinoDialogAction(
                onPressed: () => closeProxmoxModal(context),
                child: Text(l10n.commonOk),
              ),
            ],
          ),
        );
        _modal = route;
        await Navigator.of(context).push<void>(route);
        if (identical(_modal, route)) _modal = null;
      }
    } finally {
      _sent = false;
      if (mounted) setState(() => _busy = false);
    }
  }

  String _statusLabel(BuildContext context, String status) {
    final l10n = AppLocalizations.of(context);
    return switch (status) {
      'running' => l10n.proxmoxStatusRunning,
      'stopped' => l10n.proxmoxStatusStopped,
      'paused' => l10n.proxmoxStatusPaused,
      'suspended' => l10n.proxmoxStatusSuspended,
      _ => l10n.commonUnknown,
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
