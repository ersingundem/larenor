/// A connected device, from `GET /rci/show/ip/hotspot`.
class KeeneticDevice {
  const KeeneticDevice({
    required this.mac,
    required this.name,
    this.ip,
    this.active = false,
    this.interfaceId,
    this.registered = false,
  });

  final String mac;
  final String name;
  final String? ip;
  final bool active;
  final String? interfaceId;
  final bool registered;

  factory KeeneticDevice.fromJson(Map<String, dynamic> json) => KeeneticDevice(
    mac: _text(json['mac']) ?? 'unknown',
    name:
        _text(json['name']) ??
        _text(json['hostname']) ??
        _text(json['mac']) ??
        'Unknown device',
    ip: _text(json['ip']),
    active: _flag(json['active']),
    interfaceId: _text(json['via']),
    registered: _flag(json['registered']),
  );

  static String? _text(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  static bool _flag(Object? value) =>
      value == true || value == 'yes' || value == 1;
}
