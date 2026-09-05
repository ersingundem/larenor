import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../data/models/proxmox_guest.dart';
import '../data/proxmox_api_exception.dart';

bool sameProxmoxGuest(ProxmoxGuest a, ProxmoxGuest b) =>
    a.node == b.node && a.type == b.type && a.vmid == b.vmid;

/// Only explicit authorization rejections establish that a mutation did not
/// run. A lost response or accepted UPID must never become an automatic retry.
bool proxmoxMutationMayHaveRun(Object error) =>
    error is! ProxmoxApiException ||
    !const {
      ProxmoxFailure.authentication,
      ProxmoxFailure.permission,
    }.contains(error.failure);

String proxmoxMutationFailureLabel(
  AppLocalizations l10n,
  Object error, {
  bool accepted = false,
}) {
  if (accepted || proxmoxMutationMayHaveRun(error)) {
    return l10n.proxmoxActionUnknown;
  }
  return error is ProxmoxApiException &&
          error.failure == ProxmoxFailure.authentication
      ? l10n.healthAuthenticationRequired
      : l10n.healthPermissionDenied;
}

void closeProxmoxModal<T>(BuildContext context, [T? result]) {
  if (context.mounted && ModalRoute.of(context)?.isCurrent == true) {
    Navigator.pop(context, result);
  }
}

Widget proxmoxFormLabel(BuildContext context, String label) => ConstrainedBox(
  constraints: BoxConstraints(
    maxWidth: (MediaQuery.sizeOf(context).width / 3).clamp(80.0, 180.0),
  ),
  child: Text(label),
);
