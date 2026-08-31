import 'package:flutter/cupertino.dart';

import '../../../ha_client/data/models/ha_entity.dart';

/// Resolves a sensible icon for any Home Assistant entity, regardless of
/// which integration/brand produced it — HA's domain (and, for sensors,
/// `device_class`) model is brand-agnostic, so covering it broadly here is
/// what actually makes every brand (Keenetic, Anker Solix, Xiaomi, Sonoff/
/// eWeLink, Philips Hue, Apple HomeKit, and anything else HA supports)
/// render well, rather than hardcoding per-brand logic.
IconData iconForEntity(HaEntity entity) {
  final deviceClass = entity.attributes['device_class'] as String?;

  switch (entity.domain) {
    case 'light':
      return CupertinoIcons.lightbulb;
    case 'switch':
      return CupertinoIcons.power;
    case 'sensor':
      return _sensorIcon(deviceClass);
    case 'binary_sensor':
      return _binarySensorIcon(deviceClass);
    case 'climate':
      return CupertinoIcons.thermometer;
    case 'fan':
      return CupertinoIcons.wind;
    case 'input_boolean':
      return CupertinoIcons.checkmark_square;
    case 'media_player':
      return CupertinoIcons.play_circle;
    case 'cover':
      return CupertinoIcons.rectangle_split_3x1;
    case 'lock':
      return entity.state == 'locked'
          ? CupertinoIcons.lock_fill
          : CupertinoIcons.lock_open_fill;
    case 'vacuum':
      return CupertinoIcons.arrow_2_circlepath;
    case 'humidifier':
      return CupertinoIcons.drop_fill;
    case 'valve':
      return CupertinoIcons.drop;
    case 'siren':
      return CupertinoIcons.bell_fill;
    case 'alarm_control_panel':
      return CupertinoIcons.shield_fill;
    case 'update':
      return CupertinoIcons.arrow_down_circle;
    case 'number':
    case 'input_number':
      return CupertinoIcons.number;
    case 'select':
    case 'input_select':
      return CupertinoIcons.list_bullet;
    case 'button':
    case 'input_button':
      return CupertinoIcons.hand_point_right;
    case 'device_tracker':
      return CupertinoIcons.location_fill;
    case 'water_heater':
      return CupertinoIcons.flame_fill;
    case 'scene':
      return CupertinoIcons.wand_stars;
    case 'automation':
      return CupertinoIcons.bolt;
    case 'camera':
      return CupertinoIcons.videocam;
    case 'person':
      return CupertinoIcons.person_fill;
    case 'weather':
      return CupertinoIcons.cloud;
    case 'timer':
      return CupertinoIcons.timer;
    case 'script':
      return CupertinoIcons.doc_text;
    default:
      return CupertinoIcons.square_grid_2x2;
  }
}

IconData _sensorIcon(String? deviceClass) {
  switch (deviceClass) {
    case 'battery':
      return CupertinoIcons.battery_100;
    case 'power':
    case 'energy':
    case 'current':
    case 'voltage':
      return CupertinoIcons.bolt_fill;
    case 'temperature':
      return CupertinoIcons.thermometer;
    case 'humidity':
      return CupertinoIcons.drop;
    case 'illuminance':
      return CupertinoIcons.sun_max;
    case 'pressure':
      return CupertinoIcons.gauge;
    default:
      return CupertinoIcons.graph_circle;
  }
}

IconData _binarySensorIcon(String? deviceClass) {
  switch (deviceClass) {
    case 'motion':
    case 'occupancy':
    case 'presence':
      return CupertinoIcons.person_fill;
    case 'door':
    case 'window':
    case 'opening':
    case 'garage_door':
      return CupertinoIcons.rectangle_split_3x1;
    case 'moisture':
      return CupertinoIcons.drop_fill;
    case 'smoke':
    case 'gas':
    case 'safety':
    case 'problem':
      return CupertinoIcons.flame_fill;
    case 'plug':
    case 'power':
      return CupertinoIcons.bolt_fill;
    case 'connectivity':
      return CupertinoIcons.wifi;
    case 'battery':
      return CupertinoIcons.battery_100;
    default:
      return CupertinoIcons.checkmark_square;
  }
}
