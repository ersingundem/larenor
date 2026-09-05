import 'proxmox_values.dart';

class ProxmoxBackup {
  const ProxmoxBackup({
    required this.volumeId,
    this.vmid,
    this.sizeBytes,
    this.createdAt,
    this.notes,
  });

  final String volumeId;
  final int? vmid;
  final int? sizeBytes;
  final DateTime? createdAt;
  final String? notes;

  factory ProxmoxBackup.fromJson(Map<String, dynamic> json) {
    final rawTime = proxmoxInteger(json['ctime']);
    final ctime = rawTime != null && rawTime <= 8640000000000 ? rawTime : null;
    return ProxmoxBackup(
      volumeId: proxmoxIdentity(json['volid']),
      vmid: proxmoxInteger(json['vmid']),
      sizeBytes: proxmoxInteger(json['size']),
      createdAt: ctime == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(ctime * 1000),
      notes: json['notes'] as String?,
    );
  }
}
