import 'proxmox_values.dart';

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

  List<String> get powerActions {
    if (isTemplate) return const [];
    return switch (status) {
      'running' => const ['shutdown', 'stop', 'reboot', 'suspend'],
      'paused' || 'suspended' => const ['resume', 'stop'],
      'stopped' => const ['start'],
      _ => const [],
    };
  }

  double? get memFraction => proxmoxRatio(mem, maxMem);

  factory ProxmoxGuest.fromJson(
    Map<String, dynamic> json, {
    required ProxmoxGuestType type,
    required String node,
  }) => ProxmoxGuest(
    type: type,
    node: node,
    vmid:
        proxmoxInteger(json['vmid'], min: 1) ??
        (throw const FormatException('Invalid guest identity.')),
    name: json['name'] as String? ?? 'unknown',
    status: json['qmpstatus'] == 'paused'
        ? 'paused'
        : json['status'] as String? ?? 'unknown',
    isTemplate: json['template'] == null
        ? false
        : proxmoxFlag(json['template']) ??
              (throw const FormatException('Invalid template flag.')),
    cpuFraction: proxmoxFraction(json['cpu']),
    maxCpu: proxmoxInteger(json['maxcpu']),
    mem: proxmoxInteger(json['mem']),
    maxMem: proxmoxInteger(json['maxmem']),
    disk: proxmoxInteger(json['disk']),
    maxDisk: proxmoxInteger(json['maxdisk']),
    uptimeSeconds: proxmoxInteger(json['uptime']),
  );
}
