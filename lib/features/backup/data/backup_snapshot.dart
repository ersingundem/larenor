import '../../dashboard/domain/dashboard_website_url.dart';

import 'dart:convert';

import '../../../shared/network/server_bound_client.dart';
import '../../dashboard/domain/tile_config.dart';
import '../../dashboard/domain/keenetic_tile_validation.dart';
import '../../dashboard/domain/ha_area_binding.dart';
import '../../dashboard/domain/dashboard_layout_validation.dart';
import '../../intercom/domain/door_station.dart';
import '../../media/movie_night/domain/movie_night_preset.dart';
import '../../settings/data/app_service.dart';

class BackupException implements Exception {
  const BackupException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

class BackupValidationException extends BackupException {
  const BackupValidationException([
    String message = 'The backup contains unsupported or invalid data.',
  ]) : super('invalid_backup', message);
}

class BackupRestoreException extends BackupException {
  const BackupRestoreException({required this.rollbackComplete})
    : super(
        'restore_failed',
        rollbackComplete ? 'Restore failed. Previous settings were restored.' : 'Restore failed and some previous settings could not be restored. Review your connections.',
      );
  final bool rollbackComplete;
}

class BackupSelection {
  const BackupSelection({
    this.settings = true,
    this.dashboard = true,
    this.connections = false,
  });
  final bool settings;
  final bool dashboard;
  final bool connections;
  bool get isEmpty => !settings && !dashboard && !connections;
}

enum BackupConflictPolicy { keepExisting, replaceSelected }

/// This object contains secrets when connections were explicitly selected.
/// Its default toString deliberately never serializes the payload.
class BackupSnapshot {
  BackupSnapshot._(this._json);
  factory BackupSnapshot.fromJson(Map<String, dynamic> json) {
    try {
      final normalized = jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
      validateBackupJson(normalized);
      return BackupSnapshot._(normalized);
    } on BackupException {
      rethrow;
    } catch (_) {
      throw const BackupValidationException();
    }
  }
  final Map<String, dynamic> _json;
  DateTime get createdAt => DateTime.parse(_json['createdAt'] as String);
  bool get hasSettings => (_json['groups'] as Map).containsKey('settings');
  bool get hasDashboard => (_json['groups'] as Map).containsKey('dashboard');
  bool get hasConnections =>
      (_json['groups'] as Map).containsKey('connections');
  Map<String, dynamic> toJson() =>
      jsonDecode(jsonEncode(_json)) as Map<String, dynamic>;
}

/// Only counts and fixed service identifiers: never addresses, users or tokens.
class BackupPreview {
  const BackupPreview({
    required this.createdAt,
    required this.hasSettings,
    required this.hasDashboard,
    required this.hasConnections,
    required this.settingCount,
    required this.roomCount,
    required this.tileCount,
    required this.favoriteCount,
    required this.services,
    required this.existingSettingsCount,
    required this.existingDashboard,
    required this.existingServices,
    required this.requiresCertificateReview,
  });
  final DateTime createdAt;
  final bool hasSettings;
  final bool hasDashboard;
  final bool hasConnections;
  final int settingCount;
  final int roomCount;
  final int tileCount;
  final int favoriteCount;
  final List<String> services;
  final int existingSettingsCount;
  final bool existingDashboard;
  final List<String> existingServices;
  final bool requiresCertificateReview;
}

const backupPreferenceKeys = <String>{
  'keep_screen_on',
  'appearance',
  'night_start_minutes',
  'night_end_minutes',
  'dim_brightness_at_night',
  'screen_off_at_night',
  'idle_mode_enabled',
  'idle_timeout_minutes',
  'enabled_services',
  DoorStation.storageKey,
  MovieNightPreset.storageKey,
};

/// The field names are logical record fields, not an unrestricted storage dump.
const backupConnectionFields = <String, Map<String, String>>{
  'ha': {'baseUrl': 'ha_base_url', 'token': 'ha_token'},
  'jellyfin': {
    'baseUrl': 'jellyfin_base_url',
    'userId': 'jellyfin_user_id',
    'accessToken': 'jellyfin_access_token',
  },
  'jellyseerr': {
    'baseUrl': 'jellyseerr_base_url',
    'apiKey': 'jellyseerr_api_key',
  },
  'sonarr': {'baseUrl': 'sonarr_base_url', 'apiKey': 'sonarr_api_key'},
  'radarr': {'baseUrl': 'radarr_base_url', 'apiKey': 'radarr_api_key'},
  'lidarr': {'baseUrl': 'lidarr_base_url', 'apiKey': 'lidarr_api_key'},
  'readarr': {'baseUrl': 'readarr_base_url', 'apiKey': 'readarr_api_key'},
  'bazarr': {'baseUrl': 'bazarr_base_url', 'apiKey': 'bazarr_api_key'},
  'prowlarr': {'baseUrl': 'prowlarr_base_url', 'apiKey': 'prowlarr_api_key'},
  'qbittorrent': {
    'baseUrl': 'qbittorrent_base_url',
    'username': 'qbittorrent_username',
    'password': 'qbittorrent_password',
  },
  'keenetic': {
    'baseUrl': 'keenetic_base_url',
    'username': 'keenetic_username',
    'password': 'keenetic_password',
  },
  'proxmox': {
    'host': 'proxmox_host',
    'port': 'proxmox_port',
    'username': 'proxmox_username',
    'realm': 'proxmox_realm',
    'password': 'proxmox_password',
    'allowSelfSigned': 'proxmox_allow_self_signed',
  },
};

const maxBackupPlaintextBytes = 2 * 1024 * 1024;

void validateBackupJson(Object? value) {
  try {
    if (utf8.encode(jsonEncode(value)).length > maxBackupPlaintextBytes) {
      throw const BackupValidationException('The backup is too large.');
    }
    final root = _object(
      value,
      {'version', 'createdAt', 'groups'},
      required: {'version', 'createdAt', 'groups'},
    );
    if (root['version'] is! int ||
        root['version'] != 1 ||
        root['createdAt'] is! String ||
        DateTime.tryParse(root['createdAt'] as String) == null ||
        (root['createdAt'] as String).length > 40) {
      throw const BackupValidationException();
    }
    final groups = _object(root['groups'], {
      'settings',
      'dashboard',
      'connections',
    });
    if (groups.isEmpty) {
      throw const BackupValidationException(
        'Select at least one backup group.',
      );
    }
    if (groups.containsKey('settings')) _validateSettings(groups['settings']);
    if (groups.containsKey('dashboard')) {
      _validateDashboard(groups['dashboard']);
    }
    if (groups.containsKey('connections')) {
      final records = _object(
        groups['connections'],
        backupConnectionFields.keys.toSet(),
      );
      for (final entry in records.entries) {
        _validateConnection(entry.key, entry.value);
      }
    }
  } on BackupException {
    rethrow;
  } catch (_) {
    // Never include malformed source data or values in a validation error.
    throw const BackupValidationException();
  }
}

Map<String, dynamic> _object(
  Object? value,
  Set<String> allowed, {
  Set<String> required = const {},
}) {
  if (value is! Map<String, dynamic> ||
      !allowed.containsAll(value.keys) ||
      !value.keys.toSet().containsAll(required)) {
    throw const BackupValidationException();
  }
  return value;
}

void _validateSettings(Object? value) {
  final settings = _object(value, backupPreferenceKeys);
  for (final entry in settings.entries) {
    final v = entry.value;
    if (v == null) continue;
    switch (entry.key) {
      case DoorStation.storageKey:
        DoorStation.decodeStored(v);
      case MovieNightPreset.storageKey:
        MovieNightPreset.decodeStored(v);
      case 'appearance':
        if (!{'system', 'light', 'dark'}.contains(v)) {
          throw const BackupValidationException();
        }
      case 'night_start_minutes':
      case 'night_end_minutes':
        _integer(v, 0, 1439);
      case 'idle_timeout_minutes':
        _integer(v, 1, 1440);
      case 'enabled_services':
        final services = _strings(v, maxCount: AppService.values.length);
        if (!AppService.values
            .map((e) => e.name)
            .toSet()
            .containsAll(services)) {
          throw const BackupValidationException();
        }
      default:
        if (v is! bool) throw const BackupValidationException();
    }
  }
}

void _validateConnection(String service, Object? value) {
  final fields = backupConnectionFields[service]!.keys.toSet();
  final record = _object(value, fields, required: fields);
  for (final entry in record.entries) {
    _string(
      entry.value,
      maxLength: entry.key == 'baseUrl' ? 2048 : 8192,
      allowEmpty: entry.key == 'password',
    );
  }
  if (service == 'proxmox') {
    final host = record['host'] as String;
    final port = int.tryParse(record['port'] as String);
    if (port == null ||
        port < 1 ||
        port > 65535 ||
        host.contains(RegExp(r'[/\\\s@?#]')) ||
        host.isEmpty ||
        !{'true', 'false'}.contains(record['allowSelfSigned'])) {
      throw const BackupValidationException();
    }
    final uri = parseServerUrl(
      Uri(scheme: 'https', host: host, port: port).toString(),
    );
    if (uri.host.isEmpty) throw const BackupValidationException();
  } else {
    parseServerUrl(record['baseUrl'] as String);
  }
}

void _validateDashboard(Object? value) {
  final layout = _object(value, {
    'schemaVersion',
    'rooms',
    'tiles',
    'favoriteEntityIds',
    'hiddenEntityIds',
    'entityCardSizes',
    'serviceCardSizes',
  });
  if (layout.containsKey('schemaVersion')) {
    _integer(layout['schemaVersion'], 1, 2);
  }
  if (layout['rooms'] case final Object rooms) {
    if (rooms is! List || rooms.length > 500) {
      throw const BackupValidationException();
    }
    final ids = <String>{};
    for (final raw in rooms) {
      final room = _object(
        raw,
        {'id', 'name', 'entityIds', 'areaBinding'},
        required: {'id', 'name'},
      );
      if (!ids.add(_string(room['id'], maxLength: 256))) {
        throw const BackupValidationException();
      }
      _string(room['name'], maxLength: 256);
      _entityIds(room['entityIds'] ?? <String>[]);
      if (room['areaBinding'] != null) {
        try {
          validateHaAreaBindingJson(room['areaBinding']);
          final binding = HaAreaBinding.fromJson(
            room['areaBinding'] as Map<String, dynamic>,
          );
          final memberIds = (room['entityIds'] as List? ?? const [])
              .cast<String>()
              .toSet();
          if (!memberIds.containsAll(binding.importedEntityIds) ||
              memberIds
                  .intersection(binding.excludedEntityIds.toSet())
                  .isNotEmpty) {
            throw const BackupValidationException();
          }
        } catch (_) {
          throw const BackupValidationException();
        }
      }
    }
  }
  if (layout['tiles'] case final Object tiles) {
    if (tiles is! List || tiles.length > 2000) {
      throw const BackupValidationException();
    }
    final ids = <String>{};
    for (final raw in tiles) {
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
      if (!ids.add(_string(tile['id'], maxLength: 256)) ||
          !TileType.values.map((e) => e.name).contains(tile['type']) ||
          !hasValidKeeneticTileFields(tile)) {
        throw const BackupValidationException();
      }
      _integer(tile['x'], 0, 100000);
      _integer(tile['y'], 0, 100000);
      _integer(tile['width'], 1, 100);
      _integer(tile['height'], 1, 100);
      if (tile['entityId'] != null) _entityIds([tile['entityId']]);
      if (tile['title'] != null) {
        _string(tile['title'], maxLength: 512, allowEmpty: true);
      }
      if (tile['url'] != null) {
        final url = _string(tile['url'], maxLength: 4096);
        if (dashboardWebsiteUrl(url) == null) {
          throw const BackupValidationException();
        }
      }
    }
  }
  _entityIds(layout['favoriteEntityIds'] ?? <String>[]);
  _entityIds(layout['hiddenEntityIds'] ?? <String>[]);
  try {
    validateDashboardCardSizesJson(
      layout['entityCardSizes'] ?? const <String, dynamic>{},
    );
    validateDashboardCardSizesJson(
      layout['serviceCardSizes'] ?? const <String, dynamic>{},
      services: true,
    );
  } catch (_) {
    throw const BackupValidationException();
  }
}

void _integer(Object? value, int min, int max) {
  if (value is! int || value < min || value > max) {
    throw const BackupValidationException();
  }
}

String _string(
  Object? value, {
  required int maxLength,
  bool allowEmpty = false,
}) {
  if (value is! String ||
      (!allowEmpty && value.isEmpty) ||
      value.length > maxLength ||
      value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    throw const BackupValidationException();
  }
  return value;
}

List<String> _strings(Object? value, {int maxCount = 10000}) {
  if (value is! List || value.length > maxCount) {
    throw const BackupValidationException();
  }
  final result = value.map((e) => _string(e, maxLength: 256)).toList();
  if (result.toSet().length != result.length) {
    throw const BackupValidationException();
  }
  return result;
}

void _entityIds(Object? value) {
  if (!_strings(value)
      .every((e) => RegExp(r'^[a-z0-9_]+\.[a-z0-9_]+$').hasMatch(e))) {
    throw const BackupValidationException();
  }
}
