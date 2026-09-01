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
/// to `type == 'AccessPoint'`. Which field indicates "up" isn't fully
/// verified against a live router, so several plausible ones are tried.
class KeeneticAccessPoint {
  const KeeneticAccessPoint({
    required this.id,
    required this.name,
    required this.up,
  });

  final String id;
  final String name;
  final bool up;

  factory KeeneticAccessPoint.fromJson(Map<String, dynamic> json) {
    return KeeneticAccessPoint(
      id: json['id'] as String? ?? '',
      name:
          json['description'] as String? ??
          json['ssid'] as String? ??
          json['id'] as String? ??
          'Access point',
      up:
          json['state'] == 'up' ||
          json['link'] == 'up' ||
          json['connected'] == true,
    );
  }
}
