/// Read-only router identity and metrics from `show version` / `show system`.
/// Memory uses the router's reported used/total KiB pair, rather than treating
/// cache and buffers as application memory.
class KeeneticRouterStatus {
  const KeeneticRouterStatus({
    required this.model,
    this.hostname,
    this.firmware,
    this.cpuPercent,
    this.memoryUsedKiB,
    this.memoryTotalKiB,
    this.uptimeSeconds,
  });

  final String model;
  final String? hostname;
  final String? firmware;
  final int? cpuPercent;
  final int? memoryUsedKiB;
  final int? memoryTotalKiB;
  final int? uptimeSeconds;

  int? get memoryPercent {
    final used = memoryUsedKiB;
    final total = memoryTotalKiB;
    if (used == null || total == null || total <= 0) return null;
    return (used / total * 100).round().clamp(0, 100);
  }

  factory KeeneticRouterStatus.fromJson(
    Map<String, dynamic> version,
    Map<String, dynamic> system,
  ) {
    final memory = system['memory']?.toString().split('/');
    final release = version['release'];
    final cpu = int.tryParse(system['cpuload']?.toString() ?? '');
    final uptime = int.tryParse(system['uptime']?.toString() ?? '');
    return KeeneticRouterStatus(
      model:
          _text(version['model']) ??
          _text(version['description']) ??
          'Keenetic',
      hostname: _text(system['hostname']),
      firmware: _text(release) ?? _text(version['title']),
      cpuPercent: cpu?.clamp(0, 100),
      memoryUsedKiB: memory?.length == 2 ? int.tryParse(memory![0]) : null,
      memoryTotalKiB: memory?.length == 2 ? int.tryParse(memory![1]) : null,
      uptimeSeconds: uptime == null || uptime < 0 ? null : uptime,
    );
  }

  static String? _text(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;
}
