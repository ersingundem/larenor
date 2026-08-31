class ProxmoxNode {
  const ProxmoxNode({
    required this.name,
    required this.status,
    this.cpuFraction,
    this.maxCpu,
    this.mem,
    this.maxMem,
    this.disk,
    this.maxDisk,
    this.uptimeSeconds,
  });

  final String name;
  final String status;
  final double? cpuFraction;
  final int? maxCpu;
  final int? mem;
  final int? maxMem;
  final int? disk;
  final int? maxDisk;
  final int? uptimeSeconds;

  bool get isOnline => status == 'online';

  double? get memFraction =>
      (mem != null && maxMem != null && maxMem! > 0) ? mem! / maxMem! : null;

  double? get diskFraction => (disk != null && maxDisk != null && maxDisk! > 0)
      ? disk! / maxDisk!
      : null;

  factory ProxmoxNode.fromJson(Map<String, dynamic> json) => ProxmoxNode(
    name: json['node'] as String? ?? 'unknown',
    status: json['status'] as String? ?? 'unknown',
    cpuFraction: (json['cpu'] as num?)?.toDouble(),
    maxCpu: json['maxcpu'] as int?,
    mem: (json['mem'] as num?)?.toInt(),
    maxMem: (json['maxmem'] as num?)?.toInt(),
    disk: (json['disk'] as num?)?.toInt(),
    maxDisk: (json['maxdisk'] as num?)?.toInt(),
    uptimeSeconds: (json['uptime'] as num?)?.toInt(),
  );
}
