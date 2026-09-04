final RegExp _wifiInterfaceId = RegExp(r'^WifiMaster(\d+)/AccessPoint(\d+)$');

/// Parses Keenetic's raw interface id (e.g. `WifiMaster0/AccessPoint0`)
/// into its radio/AP index pair, or null if it doesn't match that shape
/// — used to render a friendly label instead of the raw id string.
(int radio, int accessPoint)? parseKeeneticWifiInterfaceId(String id) {
  final match = _wifiInterfaceId.firstMatch(id);
  if (match == null) return null;
  return (int.parse(match.group(1)!), int.parse(match.group(2)!));
}

/// A Wi-Fi access point interface, from `GET /rci/show/interface` filtered
/// to `type == 'AccessPoint'`. `state` is the administrative switch state;
/// `link` / `connected` are fallback values on firmware that omits it.
class KeeneticAccessPoint {
  const KeeneticAccessPoint({
    required this.id,
    required this.name,
    required this.up,
    this.ssid,
  });

  final String id;
  final String name;
  final bool up;
  final String? ssid;

  factory KeeneticAccessPoint.fromJson(Map<String, dynamic> json) {
    return KeeneticAccessPoint(
      id: json['id'] as String? ?? '',
      name:
          _text(json['description']) ??
          _text(json['ssid']) ??
          _text(json['id']) ??
          'Access point',
      ssid: _text(json['ssid']),
      up: json['state'] != null
          ? json['state'] == 'up'
          : json['link'] != null
          ? json['link'] == 'up'
          : json['connected'] == true || json['connected'] == 'yes',
    );
  }

  static String? _text(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;
}
