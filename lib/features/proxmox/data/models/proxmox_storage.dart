import 'proxmox_values.dart';

import 'proxmox_guest.dart';

class ProxmoxStorage {
  const ProxmoxStorage({
    required this.name,
    required this.type,
    required this.contentTypes,
    this.total,
    this.used,
    this.available,
    bool? active = true,
    bool? enabled = true,
  }) : activeState = active,
       enabledState = enabled;

  final String name;
  final String type;
  final List<String> contentTypes;
  final int? total;
  final int? used;
  final int? available;
  final bool? activeState;
  final bool? enabledState;
  bool get active => activeState == true;
  bool get enabled => enabledState == true;

  double? get usedFraction => proxmoxRatio(used, total);

  bool get supportsBackups =>
      active && enabled && contentTypes.contains('backup');

  bool supportsGuestType(ProxmoxGuestType type) =>
      active &&
      enabled &&
      contentTypes.contains(
        type == ProxmoxGuestType.qemu ? 'images' : 'rootdir',
      );

  bool get supportsTemplates =>
      contentTypes.contains('images') || contentTypes.contains('rootdir');

  factory ProxmoxStorage.fromJson(Map<String, dynamic> json) => ProxmoxStorage(
    name: proxmoxIdentity(json['storage']),
    type: json['type'] as String? ?? 'unknown',
    contentTypes:
        (json['content'] as String?)
            ?.split(',')
            .map((e) => e.trim())
            .toList() ??
        const [],
    total: proxmoxInteger(json['total']),
    used: proxmoxInteger(json['used']),
    available: proxmoxInteger(json['avail']),
    active: proxmoxFlag(json['active']),
    enabled: proxmoxFlag(json['enabled']),
  );
}
