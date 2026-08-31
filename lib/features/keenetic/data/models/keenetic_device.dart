/// A connected device, from `GET /rci/show/ip/hotspot`.
class KeeneticDevice {
  const KeeneticDevice({
    required this.mac,
    required this.name,
    this.ip,
    this.active = false,
  });

  final String mac;
  final String name;
  final String? ip;
  final bool active;

  factory KeeneticDevice.fromJson(Map<String, dynamic> json) => KeeneticDevice(
    mac: json['mac'] as String? ?? 'unknown',
    name:
        json['name'] as String? ??
        json['hostname'] as String? ??
        json['mac'] as String? ??
        'Unknown device',
    ip: json['ip'] as String?,
    active: json['active'] as bool? ?? false,
  );
}
