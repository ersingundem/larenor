class ProxmoxStorage {
  const ProxmoxStorage({
    required this.name,
    required this.type,
    required this.contentTypes,
    this.total,
    this.used,
    this.available,
    this.active = true,
  });

  final String name;
  final String type;
  final List<String> contentTypes;
  final int? total;
  final int? used;
  final int? available;
  final bool active;

  double? get usedFraction =>
      (used != null && total != null && total! > 0) ? used! / total! : null;

  bool get supportsBackups => contentTypes.contains('backup');

  bool get supportsTemplates =>
      contentTypes.contains('images') || contentTypes.contains('rootdir');

  factory ProxmoxStorage.fromJson(Map<String, dynamic> json) => ProxmoxStorage(
    name: json['storage'] as String? ?? 'unknown',
    type: json['type'] as String? ?? 'unknown',
    contentTypes:
        (json['content'] as String?)
            ?.split(',')
            .map((e) => e.trim())
            .toList() ??
        const [],
    total: (json['total'] as num?)?.toInt(),
    used: (json['used'] as num?)?.toInt(),
    available: (json['avail'] as num?)?.toInt(),
    active: (json['active'] as num? ?? 1) == 1,
  );
}
