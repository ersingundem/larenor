import 'dashboard_website_url.dart';

import 'dart:convert';

import 'ha_area_binding.dart';
import 'dashboard_card_size.dart';
import '../../settings/data/app_service.dart';
import 'tile_config.dart';
import 'keenetic_tile_validation.dart';

const maxDashboardLayoutBytes = 2 * 1024 * 1024;

/// Shared local persistence schema. Legacy layouts without schemaVersion and
/// areaBinding remain unbound; no server-derived migration runs on load.
void validateDashboardLayoutJson(Object? value) {
  const invalid = FormatException('Invalid dashboard layout');
  if (utf8.encode(jsonEncode(value)).length > maxDashboardLayoutBytes) {
    throw invalid;
  }
  final layout = _object(value, {
    'schemaVersion',
    'rooms',
    'tiles',
    'favoriteEntityIds',
    'hiddenEntityIds',
    'entityCardSizes',
    'serviceCardSizes',
  });
  final version = layout['schemaVersion'];
  if (layout.containsKey('schemaVersion') &&
      (version is! int || version < 1 || version > 2)) {
    throw invalid;
  }
  final rooms = _list(layout['rooms'] ?? const [], 500);
  final roomIds = <String>{};
  for (final raw in rooms) {
    final room = _object(
      raw,
      {'id', 'name', 'entityIds', 'areaBinding'},
      required: {'id', 'name'},
    );
    if (!roomIds.add(_string(room['id'], 256))) throw invalid;
    _string(room['name'], 256);
    final ids = _entityIds(room['entityIds'] ?? const []);
    if (room['areaBinding'] != null) {
      validateHaAreaBindingJson(room['areaBinding']);
      final binding = HaAreaBinding.fromJson(
        room['areaBinding'] as Map<String, dynamic>,
      );
      if (!ids.containsAll(binding.importedEntityIds) ||
          ids.intersection(binding.excludedEntityIds.toSet()).isNotEmpty) {
        throw invalid;
      }
    }
  }
  final tileIds = <String>{};
  for (final raw in _list(layout['tiles'] ?? const [], 2000)) {
    final tile = _object(
      raw,
      {
        'id',
        'type',
        'x',
        'y',
        'width',
        'height',
        'entityId',
        'url',
        'title',
        'keeneticMetric',
        'keeneticInterfaceId',
      },
      required: {'id', 'type', 'x', 'y', 'width', 'height'},
    );
    if (!tileIds.add(_string(tile['id'], 256)) ||
        !TileType.values.any((type) => type.name == tile['type']) ||
        !hasValidKeeneticTileFields(tile)) {
      throw invalid;
    }
    _integer(tile['x'], 0, 100000);
    _integer(tile['y'], 0, 100000);
    _integer(tile['width'], 1, 100);
    _integer(tile['height'], 1, 100);
    if (tile['entityId'] != null) _entityIds([tile['entityId']]);
    if (tile['title'] != null) _string(tile['title'], 512, allowEmpty: true);
    if (tile['url'] != null) {
      final url = _string(tile['url'], 4096);
      if (dashboardWebsiteUrl(url) == null) {
        throw invalid;
      }
    }
  }
  _entityIds(layout['favoriteEntityIds'] ?? const []);
  _entityIds(layout['hiddenEntityIds'] ?? const []);
  validateDashboardCardSizesJson(
    layout['entityCardSizes'] ?? const <String, dynamic>{},
  );
  validateDashboardCardSizesJson(
    layout['serviceCardSizes'] ?? const <String, dynamic>{},
    services: true,
  );
}

Map<String, dynamic> _object(
  Object? value,
  Set<String> allowed, {
  Set<String> required = const {},
}) {
  if (value is! Map<String, dynamic> ||
      !allowed.containsAll(value.keys) ||
      !value.keys.toSet().containsAll(required)) {
    throw const FormatException('Invalid dashboard layout');
  }
  return value;
}

List<dynamic> _list(Object? value, int max) {
  if (value is! List || value.length > max) {
    throw const FormatException('Invalid dashboard layout');
  }
  return value;
}

String _string(Object? value, int max, {bool allowEmpty = false}) {
  if (value is! String ||
      (!allowEmpty && value.isEmpty) ||
      value.length > max ||
      value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    throw const FormatException('Invalid dashboard layout');
  }
  return value;
}

void _integer(Object? value, int min, int max) {
  if (value is! int || value < min || value > max) {
    throw const FormatException('Invalid dashboard layout');
  }
}

Set<String> _entityIds(Object? value) {
  final ids = <String>{};
  for (final raw in _list(value, 10000)) {
    final id = _string(raw, 256);
    if (!RegExp(r'^[a-z0-9_]+\.[a-z0-9_]+$').hasMatch(id) || !ids.add(id)) {
      throw const FormatException('Invalid dashboard layout');
    }
  }
  return ids;
}

/// Shared by local persistence and portable backup validation.
void validateDashboardCardSizesJson(Object? value, {bool services = false}) {
  const invalid = FormatException('Invalid dashboard card sizes');
  if (value is! Map<String, dynamic> ||
      value.length > (services ? AppService.values.length : 10000)) {
    throw invalid;
  }
  final serviceKeys = {for (final service in AppService.values) service.name};
  final sizes = {for (final size in DashboardCardSize.values) size.name};
  for (final entry in value.entries) {
    if (!sizes.contains(entry.value)) throw invalid;
    if (services) {
      if (!serviceKeys.contains(entry.key)) throw invalid;
    } else {
      _entityIds([entry.key]);
    }
  }
}
