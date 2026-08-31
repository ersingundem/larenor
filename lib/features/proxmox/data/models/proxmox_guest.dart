enum ProxmoxGuestType {
  qemu,
  lxc;

  /// The API resource path segment for this guest type ('qemu' or 'lxc').
  String get resourcePath => switch (this) {
    ProxmoxGuestType.qemu => 'qemu',
    ProxmoxGuestType.lxc => 'lxc',
  };

  String get label => switch (this) {
    ProxmoxGuestType.qemu => 'VM',
    ProxmoxGuestType.lxc => 'Container',
  };
}

class ProxmoxGuest {
  const ProxmoxGuest({
    required this.type,
    required this.node,
    required this.vmid,
    required this.name,
    required this.status,
    this.isTemplate = false,
    this.cpuFraction,
    this.maxCpu,
    this.mem,
    this.maxMem,
    this.disk,
    this.maxDisk,
    this.uptimeSeconds,
  });

  final ProxmoxGuestType type;
  final String node;
  final int vmid;
  final String name;
  final String status;
  final bool isTemplate;
  final double? cpuFraction;
  final int? maxCpu;
  final int? mem;
  final int? maxMem;
  final int? disk;
  final int? maxDisk;
  final int? uptimeSeconds;

  bool get isRunning => status == 'running';

  double? get memFraction =>
      (mem != null && maxMem != null && maxMem! > 0) ? mem! / maxMem! : null;

  factory ProxmoxGuest.fromJson(
    Map<String, dynamic> json, {
    required ProxmoxGuestType type,
    required String node,
  }) => ProxmoxGuest(
    type: type,
    node: node,
    vmid: (json['vmid'] as num?)?.toInt() ?? 0,
    name: json['name'] as String? ?? 'unknown',
    status: json['status'] as String? ?? 'unknown',
    isTemplate: (json['template'] as num? ?? 0) == 1,
    cpuFraction: (json['cpu'] as num?)?.toDouble(),
    maxCpu: (json['maxcpu'] as num?)?.toInt(),
    mem: (json['mem'] as num?)?.toInt(),
    maxMem: (json['maxmem'] as num?)?.toInt(),
    disk: (json['disk'] as num?)?.toInt(),
    maxDisk: (json['maxdisk'] as num?)?.toInt(),
    uptimeSeconds: (json['uptime'] as num?)?.toInt(),
  );
}
