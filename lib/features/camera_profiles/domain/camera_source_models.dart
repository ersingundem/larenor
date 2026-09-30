import '../../server/domain/server_models.dart';

final class CameraSourceChoice {
  const CameraSourceChoice(this.id, this.name, this.domain);
  final String id, name, domain;
}

final class CameraSourceState {
  const CameraSourceState(
    this.revision,
    this.resources,
    this.areas,
    this.settings,
  );
  final int revision;
  final List<CameraSourceChoice> resources, areas;
  final Map<String, dynamic>? settings;

  static CameraSourceState decode(Map<String, dynamic> raw) {
    const keys = {
      'schemaVersion',
      'revision',
      'resources',
      'areas',
      'settings',
    };
    if (raw.keys.toSet().difference(keys).isNotEmpty ||
        raw.length != keys.length ||
        raw['schemaVersion'] != 1 ||
        raw['revision'] is! int ||
        (raw['revision'] as int) < 0) {
      throw const LarenorServerException('invalid_response');
    }
    List<CameraSourceChoice> choices(Object? value, bool areas) {
      if (value is! List || value.length > 512) {
        throw const LarenorServerException('invalid_response');
      }
      final result = <CameraSourceChoice>[];
      final ids = <String>{};
      for (final item in value) {
        if (item is! Map<String, dynamic> ||
            item.length != (areas ? 2 : 3) ||
            !item.keys.every(
              (key) => {'id', 'name', if (!areas) 'domain'}.contains(key),
            ) ||
            item['id'] is! String ||
            !RegExp(r'^[0-9a-f]{32}$').hasMatch(item['id'] as String) ||
            item['name'] is! String ||
            (item['name'] as String).isEmpty ||
            (item['name'] as String).length > 80 ||
            (item['name'] as String).contains(RegExp(r'[\x00-\x1f\x7f]')) ||
            !ids.add(item['id'] as String) ||
            !areas &&
                !{
                  'switch',
                  'person',
                  'device_tracker',
                  'binary_sensor',
                }.contains(item['domain'])) {
          throw const LarenorServerException('invalid_response');
        }
        result.add(
          CameraSourceChoice(
            item['id'] as String,
            item['name'] as String,
            areas ? 'room' : item['domain'] as String,
          ),
        );
      }
      return List.unmodifiable(result);
    }

    final settings = raw['settings'];
    if (settings != null) {
      if (settings is! Map<String, dynamic>) {
        throw const LarenorServerException('invalid_response');
      }
      validateSettings(settings);
    }
    if ((raw['revision'] == 0) != (settings == null)) {
      throw const LarenorServerException('invalid_response');
    }
    return CameraSourceState(
      raw['revision'] as int,
      choices(raw['resources'], false),
      choices(raw['areas'], true),
      settings == null
          ? null
          : Map.unmodifiable(settings as Map<String, dynamic>),
    );
  }

  static void validateSettings(Map<String, dynamic> raw) {
    const keys = {
      'schemaVersion',
      'expectedRevision',
      'presenceResourceId',
      'cameras',
      'enterDelayMs',
      'exitDelayMs',
      'hysteresisMs',
      'presenceMaxAgeMs',
      'atHomeMode',
      'awayMode',
      'failSafeMode',
    };
    bool id(Object? value) =>
        value is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(value);
    bool number(String name, int minimum, int maximum) =>
        raw[name] is int &&
        (raw[name] as int) >= minimum &&
        (raw[name] as int) <= maximum;
    if (raw.length != keys.length ||
        !raw.keys.every(keys.contains) ||
        raw['schemaVersion'] != 1 ||
        !number('expectedRevision', 0, 0x7ffffffffffffffe) ||
        !id(raw['presenceResourceId']) ||
        !number('enterDelayMs', 0, 3600000) ||
        !number('exitDelayMs', 0, 3600000) ||
        !number('hysteresisMs', 0, 900000) ||
        !number('presenceMaxAgeMs', 1000, 86400000)) {
      throw const LarenorServerException('invalid_response');
    }
    final cameras = raw['cameras'];
    if (cameras is! List || cameras.isEmpty || cameras.length > 16) {
      throw const LarenorServerException('invalid_response');
    }
    final ids = <Object?>{raw['presenceResourceId']};
    for (final camera in cameras) {
      if (camera is! Map ||
          camera.length != 3 ||
          !camera.keys.every(
            {'recordingResourceId', 'detectionResourceId', 'areaId'}.contains,
          ) ||
          !camera.values.every(id) ||
          !ids.add(camera['recordingResourceId']) ||
          !ids.add(camera['detectionResourceId'])) {
        throw const LarenorServerException('invalid_response');
      }
    }
    for (final key in ['atHomeMode', 'awayMode', 'failSafeMode']) {
      final mode = raw[key];
      if (mode is! Map ||
          mode.length != 2 ||
          !mode.keys.every({'recording', 'detection'}.contains) ||
          !{'enabled', 'paused'}.contains(mode['recording']) ||
          !{'enabled', 'disabled'}.contains(mode['detection']) ||
          key == 'failSafeMode' && mode['recording'] != 'enabled') {
        throw const LarenorServerException('invalid_response');
      }
    }
  }
}

final class CameraSourceRecovery {
  const CameraSourceRecovery._(this.commandId, this.label, this.request);
  final String commandId, label;
  final Map<String, dynamic> request;
  String get recording => (request['mode'] as Map)['recording'] as String;
  String get detection => (request['mode'] as Map)['detection'] as String;

  static CameraSourceRecovery decode(Map<String, dynamic> value) {
    const keys = {
      'schemaVersion',
      'commandId',
      'cameraId',
      'expectedSourceRevision',
      'expectedStateRevision',
      'mode',
      'label',
    };
    bool id(Object? raw) =>
        raw is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(raw);
    final mode = value['mode'], label = value['label'];
    if (value.length != keys.length ||
        !value.keys.every(keys.contains) ||
        value['schemaVersion'] != 1 ||
        !id(value['commandId']) ||
        !id(value['cameraId']) ||
        value['expectedSourceRevision'] is! int ||
        (value['expectedSourceRevision'] as int) < 1 ||
        value['expectedStateRevision'] is! int ||
        (value['expectedStateRevision'] as int) < 1 ||
        mode is! Map ||
        mode.length != 2 ||
        !mode.keys.every({'recording', 'detection'}.contains) ||
        !{'enabled', 'paused'}.contains(mode['recording']) ||
        !{'enabled', 'disabled'}.contains(mode['detection']) ||
        label is! String ||
        label.isEmpty ||
        label.length > 80 ||
        label.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw const LarenorServerException('invalid_response');
    }
    return CameraSourceRecovery._(
      value['commandId'] as String,
      label,
      Map.unmodifiable({
        for (final entry in value.entries)
          if (entry.key != 'label') entry.key: entry.value,
      }),
    );
  }
}
