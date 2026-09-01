import 'package:flutter/cupertino.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../data/models/proxmox_guest.dart';

/// Localized label for a [ProxmoxGuestType], since the enum itself lives
/// in the data layer and can't call [AppLocalizations.of] directly.
String proxmoxGuestTypeLabel(BuildContext context, ProxmoxGuestType type) {
  final l10n = AppLocalizations.of(context);
  return switch (type) {
    ProxmoxGuestType.qemu => l10n.proxmoxGuestTypeVm,
    ProxmoxGuestType.lxc => l10n.proxmoxGuestTypeContainer,
  };
}
