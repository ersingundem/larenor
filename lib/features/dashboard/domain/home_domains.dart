import '../../ha_client/data/models/ha_entity.dart';

/// Entity domains worth putting on the home screen.
///
/// A real Home Assistant instance exposes hundreds of entities, most of
/// them diagnostic (firmware versions, signal strengths, update checkers).
/// Apple Home only ever shows actual accessories, so the dashboard filters
/// down to domains that are either controllable or genuinely worth
/// glancing at on a wall panel.
const kHomeDomains = {
  'light',
  'switch',
  'input_boolean',
  'fan',
  'cover',
  'lock',
  'climate',
  'media_player',
  'scene',
  'camera',
  'vacuum',
  'humidifier',
  'water_heater',
  'valve',
  'siren',
  'alarm_control_panel',
  'weather',
  'sensor',
  'binary_sensor',
};

/// `sensor`/`binary_sensor` are the two domains HA uses as a catch-all, so
/// they're only surfaced when their `device_class` is one that maps to
/// something Apple Home would actually display — a room's temperature or
/// humidity reading, or a door/motion/leak state. Everything else (signal
/// strength, uptime, battery voltage, …) stays hidden.
const kHomeSensorDeviceClasses = {
  'temperature',
  'humidity',
  'motion',
  'occupancy',
  'presence',
  'door',
  'window',
  'garage_door',
  'opening',
  'smoke',
  'gas',
  'moisture',
  'co',
  'co2',
  'illuminance',
};

/// The category chips across the top of the dashboard, mirroring Apple
/// Home's own filter row.
enum HomeCategory { lights, climate, security, media, other }

/// Whether [entity] belongs on the home dashboard at all.
bool isHomeEntity(HaEntity entity) {
  final domain = entity.domain;
  if (!kHomeDomains.contains(domain)) return false;
  if (domain == 'sensor' || domain == 'binary_sensor') {
    final deviceClass = entity.attributes['device_class'] as String?;
    return deviceClass != null &&
        kHomeSensorDeviceClasses.contains(deviceClass);
  }
  return true;
}

/// Which filter chip [entity] falls under.
HomeCategory homeCategoryForEntity(HaEntity entity) {
  switch (entity.domain) {
    case 'light':
      return HomeCategory.lights;
    case 'climate':
    case 'humidifier':
    case 'water_heater':
    case 'fan':
    case 'weather':
      return HomeCategory.climate;
    case 'lock':
    case 'camera':
    case 'alarm_control_panel':
    case 'siren':
    case 'cover':
      return HomeCategory.security;
    case 'media_player':
      return HomeCategory.media;
    case 'sensor':
    case 'binary_sensor':
      return _sensorCategory(entity.attributes['device_class'] as String?);
    default:
      return HomeCategory.other;
  }
}

HomeCategory _sensorCategory(String? deviceClass) {
  switch (deviceClass) {
    case 'temperature':
    case 'humidity':
    case 'co2':
      return HomeCategory.climate;
    case 'motion':
    case 'occupancy':
    case 'presence':
    case 'door':
    case 'window':
    case 'garage_door':
    case 'opening':
    case 'smoke':
    case 'gas':
    case 'co':
    case 'moisture':
      return HomeCategory.security;
    default:
      return HomeCategory.other;
  }
}
