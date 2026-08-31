import 'package:flutter/cupertino.dart';

/// Assigns a Cupertino system color to a Home Assistant entity domain (and,
/// for sensors, `device_class`) — reusing Flutter's own dynamic, light/
/// dark-aware system palette rather than inventing new colors, so entity
/// tiles read as color-coded categories the way Apple Home's accessory
/// tiles do, instead of every icon sharing one flat accent color.
Color categoryColorForDomain(String domain, {String? deviceClass}) {
  switch (domain) {
    case 'light':
      return CupertinoColors.systemYellow;
    case 'switch':
    case 'input_boolean':
    case 'update':
      return CupertinoColors.systemBlue;
    case 'sensor':
    case 'binary_sensor':
      return _sensorColor(deviceClass);
    case 'climate':
    case 'water_heater':
    case 'timer':
      return CupertinoColors.systemOrange;
    case 'fan':
    case 'humidifier':
    case 'valve':
      return CupertinoColors.systemCyan;
    case 'media_player':
    case 'scene':
      return CupertinoColors.systemPurple;
    case 'cover':
      return CupertinoColors.systemBrown;
    case 'lock':
    case 'siren':
    case 'alarm_control_panel':
      return CupertinoColors.systemRed;
    case 'vacuum':
    case 'automation':
    case 'camera':
      return CupertinoColors.systemIndigo;
    case 'device_tracker':
    case 'person':
      return CupertinoColors.systemGreen;
    case 'weather':
      return CupertinoColors.systemBlue;
    default:
      return CupertinoColors.systemGrey;
  }
}

Color _sensorColor(String? deviceClass) {
  switch (deviceClass) {
    case 'battery':
      return CupertinoColors.systemGreen;
    case 'power':
    case 'energy':
    case 'current':
    case 'voltage':
    case 'plug':
      return CupertinoColors.systemYellow;
    case 'temperature':
      return CupertinoColors.systemOrange;
    case 'humidity':
    case 'moisture':
      return CupertinoColors.systemCyan;
    case 'motion':
    case 'occupancy':
    case 'presence':
      return CupertinoColors.systemGreen;
    case 'door':
    case 'window':
    case 'opening':
    case 'garage_door':
      return CupertinoColors.systemBrown;
    case 'smoke':
    case 'gas':
    case 'safety':
    case 'problem':
      return CupertinoColors.systemRed;
    case 'connectivity':
      return CupertinoColors.systemBlue;
    default:
      return CupertinoColors.systemTeal;
  }
}
