import '../../domain/server_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');

Map<Object?, Object?> _object(Object? raw, Set<String> keys) {
  if (raw is! Map ||
      raw.length != keys.length ||
      !keys.every(raw.containsKey)) {
    _invalid();
  }
  return raw;
}

String _id(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

int _revision(Object? value) {
  if (value is! int || value < 1 || value > 9223372036854775807) {
    _invalid();
  }
  return value;
}

void _policy(Object? limits, Object? denials) {
  final value = _object(limits, {'filesystem', 'network', 'output'});
  final filesystem = _object(value['filesystem'], {
    'mode',
    'scratchBytes',
    'hostPathsAvailable',
  });
  final network = _object(value['network'], {'mode', 'allowedDestinations'});
  final output = _object(value['output'], {'maxBytesPerInvocation'});
  final denied = _object(denials, {
    'crossHomeAccess',
    'secretsAvailable',
    'hostManagementAvailable',
    'arbitraryCodeAvailable',
  });
  if (filesystem['mode'] != 'none' ||
      filesystem['scratchBytes'] != 0 ||
      filesystem['hostPathsAvailable'] != false ||
      network['mode'] != 'deny_all' ||
      network['allowedDestinations'] is! List ||
      (network['allowedDestinations'] as List).isNotEmpty ||
      output['maxBytesPerInvocation'] != 1024 ||
      denied.values.any((value) => value != false)) {
    _invalid();
  }
}

void _capabilities(Object? raw) {
  if (raw is! List ||
      raw.length != 1 ||
      raw.single != 'home.resource_count.read') {
    _invalid();
  }
}

final class ServerMiniPluginCatalog {
  const ServerMiniPluginCatalog._();

  factory ServerMiniPluginCatalog.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'catalogVersion',
      'templates',
    });
    final templates = value['templates'];
    if (value['schemaVersion'] != 2 ||
        value['catalogVersion'] != 'mini-plugin-catalog-v2' ||
        templates is! List ||
        templates.length != 1) {
      _invalid();
    }
    final template = _object(templates.single, {
      'schemaVersion',
      'id',
      'displayName',
      'executionClass',
      'capabilities',
      'limits',
      'denials',
      'operations',
    });
    final operations = template['operations'];
    if (template['schemaVersion'] != 2 ||
        template['id'] != 'home-resource-count' ||
        template['displayName'] != 'Home resource count' ||
        template['executionClass'] != 'builtin_metadata_v2' ||
        operations is! List ||
        operations.length != 2 ||
        operations[0] != 'render' ||
        operations[1] != 'stop') {
      _invalid();
    }
    _capabilities(template['capabilities']);
    _policy(template['limits'], template['denials']);
    return const ServerMiniPluginCatalog._();
  }
}

final class ServerMiniPluginInstance {
  const ServerMiniPluginInstance._({
    required this.id,
    required this.revision,
    required this.displayName,
    required this.state,
  });

  factory ServerMiniPluginInstance.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'id',
      'revision',
      'templateId',
      'displayName',
      'state',
      'executionClass',
      'capabilities',
      'limits',
      'denials',
      'createdAt',
      'updatedAt',
    });
    final name = value['displayName'];
    final state = value['state'];
    if (value['schemaVersion'] != 2 ||
        value['templateId'] != 'home-resource-count' ||
        value['executionClass'] != 'builtin_metadata_v2' ||
        name is! String ||
        name.isEmpty ||
        name.runes.length > 48 ||
        state != 'running' && state != 'stopped' ||
        value['createdAt'] is! num ||
        value['updatedAt'] is! num) {
      _invalid();
    }
    _capabilities(value['capabilities']);
    _policy(value['limits'], value['denials']);
    return ServerMiniPluginInstance._(
      id: _id(value['id']),
      revision: _revision(value['revision']),
      displayName: name,
      state: state as String,
    );
  }

  final String id, displayName, state;
  final int revision;
  bool get running => state == 'running';
}

final class ServerMiniPluginSnapshot {
  const ServerMiniPluginSnapshot._({
    required this.pluginId,
    required this.pluginRevision,
    required this.resourceCount,
    required this.generatedAt,
  });

  factory ServerMiniPluginSnapshot.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'pluginId',
      'pluginRevision',
      'capability',
      'resourceCount',
      'generatedAt',
      'networkRequests',
      'filesystemBytes',
      'secretReads',
      'hostOperations',
      'outputBytesMaximum',
    });
    final count = value['resourceCount'];
    final generated = value['generatedAt'];
    if (value['schemaVersion'] != 2 ||
        value['capability'] != 'home.resource_count.read' ||
        count is! int ||
        count < 0 ||
        count > 512 ||
        generated is! num ||
        !generated.isFinite ||
        value['networkRequests'] != 0 ||
        value['filesystemBytes'] != 0 ||
        value['secretReads'] != 0 ||
        value['hostOperations'] != 0 ||
        value['outputBytesMaximum'] != 1024) {
      _invalid();
    }
    return ServerMiniPluginSnapshot._(
      pluginId: _id(value['pluginId']),
      pluginRevision: _revision(value['pluginRevision']),
      resourceCount: count,
      generatedAt: DateTime.fromMillisecondsSinceEpoch(
        (generated * 1000).round(),
        isUtc: true,
      ),
    );
  }

  final String pluginId;
  final int pluginRevision, resourceCount;
  final DateTime generatedAt;
}
