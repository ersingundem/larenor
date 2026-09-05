import 'proxmox_values.dart';

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

  double? get memFraction => proxmoxRatio(mem, maxMem);

  double? get diskFraction => proxmoxRatio(disk, maxDisk);

  factory ProxmoxNode.fromJson(Map<String, dynamic> json) => ProxmoxNode(
    name: proxmoxIdentity(json['node']),
    status: json['status'] as String? ?? 'unknown',
    cpuFraction: proxmoxFraction(json['cpu']),
    maxCpu: proxmoxInteger(json['maxcpu']),
    mem: proxmoxInteger(json['mem']),
    maxMem: proxmoxInteger(json['maxmem']),
    disk: proxmoxInteger(json['disk']),
    maxDisk: proxmoxInteger(json['maxdisk']),
    uptimeSeconds: proxmoxInteger(json['uptime']),
  );
}
