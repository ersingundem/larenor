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
    final ctime = (json['ctime'] as num?)?.toInt();
    return ProxmoxBackup(
      volumeId: json['volid'] as String? ?? 'unknown',
      vmid: (json['vmid'] as num?)?.toInt(),
      sizeBytes: (json['size'] as num?)?.toInt(),
      createdAt: ctime == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(ctime * 1000),
      notes: json['notes'] as String?,
    );
  }
}
