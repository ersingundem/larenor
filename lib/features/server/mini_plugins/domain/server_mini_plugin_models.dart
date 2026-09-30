import '../../domain/server_models.dart';

const _artifactSha256 =
    '7bdd159c4e384d2413d04b0bbf6ee8b26c4ea179c089258269e44accee04a8bf';
const _manifestSha256 =
    'd9d6888d352881fc02d0123160345648417621b6943c6a98212a25ced1578a28';

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
  final value = _object(limits, {
    'filesystem',
    'network',
    'compute',
    'memory',
    'output',
  });
  final filesystem = _object(value['filesystem'], {
    'mode',
    'scratchBytes',
    'hostPathsAvailable',
  });
  final network = _object(value['network'], {'mode', 'allowedDestinations'});
  final compute = _object(value['compute'], {
    'engine',
    'fuelUnitsPerInvocation',
    'epochDeadlineTicks',
    'epochIncrementAfterMilliseconds',
  });
  final memory = _object(value['memory'], {
    'maxLinearBytes',
    'maximumMemories',
    'maximumTables',
  });
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
      compute['engine'] != 'wasmtime-49.0.0' ||
      compute['fuelUnitsPerInvocation'] != 50000 ||
      compute['epochDeadlineTicks'] != 1 ||
      compute['epochIncrementAfterMilliseconds'] != 100 ||
      memory['maxLinearBytes'] != 65536 ||
      memory['maximumMemories'] != 1 ||
      memory['maximumTables'] != 0 ||
      output['maxBytesPerInvocation'] != 1024 ||
      denied.values.any((value) => value != false)) {
    _invalid();
  }
}

void _runtime(Object? raw) {
  final value = _object(raw, {
    'artifactId',
    'artifactVersion',
    'artifactSha256',
    'manifestSha256',
    'manifestSignatureAlgorithm',
    'manifestSignatureVerified',
    'abi',
    'engine',
    'allowedImports',
    'wasiEnabled',
  });
  final imports = value['allowedImports'];
  if (value['artifactId'] != 'home-resource-count' ||
      value['artifactVersion'] != 1 ||
      value['artifactSha256'] != _artifactSha256 ||
      value['manifestSha256'] != _manifestSha256 ||
      value['manifestSignatureAlgorithm'] != 'Ed25519' ||
      value['manifestSignatureVerified'] != true ||
      value['abi'] != 'larenor.mini-plugin.v1' ||
      value['engine'] != 'wasmtime-49.0.0' ||
      imports is! List ||
      imports.length != 1 ||
      imports.single != 'larenor.current_home_resource_count()->i32' ||
      value['wasiEnabled'] != false) {
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
    if (value['schemaVersion'] != 3 ||
        value['catalogVersion'] != 'mini-plugin-catalog-v3' ||
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
      'runtime',
      'operations',
    });
    final operations = template['operations'];
    if (template['schemaVersion'] != 3 ||
        template['id'] != 'home-resource-count' ||
        template['displayName'] != 'Home resource count' ||
        template['executionClass'] != 'signed_packaged_wasm_v1' ||
        operations is! List ||
        operations.length != 2 ||
        operations[0] != 'render' ||
        operations[1] != 'stop') {
      _invalid();
    }
    _capabilities(template['capabilities']);
    _policy(template['limits'], template['denials']);
    _runtime(template['runtime']);
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
    if (value['schemaVersion'] != 3 ||
        value['templateId'] != 'home-resource-count' ||
        value['executionClass'] != 'signed_packaged_wasm_v1' ||
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
    required this.artifactSha256,
    required this.fuelConsumed,
    required this.linearMemoryBytesObserved,
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
      'hostCapabilityCalls',
      'hostManagementOperations',
      'outputBytesMaximum',
      'runtimeEvidence',
    });
    final count = value['resourceCount'];
    final generated = value['generatedAt'];
    final evidence = _object(value['runtimeEvidence'], {
      'artifactSha256',
      'manifestSha256',
      'manifestSignatureVerified',
      'engine',
      'fuelLimit',
      'fuelConsumed',
      'linearMemoryLimitBytes',
      'linearMemoryBytesObserved',
      'epochDeadlineTicks',
      'epochIncrementAfterMilliseconds',
      'wasiEnabled',
      'allowedImports',
    });
    final fuelConsumed = evidence['fuelConsumed'];
    final imports = evidence['allowedImports'];
    if (value['schemaVersion'] != 3 ||
        value['capability'] != 'home.resource_count.read' ||
        count is! int ||
        count < 0 ||
        count > 512 ||
        generated is! num ||
        !generated.isFinite ||
        value['networkRequests'] != 0 ||
        value['filesystemBytes'] != 0 ||
        value['secretReads'] != 0 ||
        value['hostCapabilityCalls'] != 1 ||
        value['hostManagementOperations'] != 0 ||
        value['outputBytesMaximum'] != 1024 ||
        evidence['artifactSha256'] != _artifactSha256 ||
        evidence['manifestSha256'] != _manifestSha256 ||
        evidence['manifestSignatureVerified'] != true ||
        evidence['engine'] != 'wasmtime-49.0.0' ||
        evidence['fuelLimit'] != 50000 ||
        fuelConsumed is! int ||
        fuelConsumed < 1 ||
        fuelConsumed > 50000 ||
        evidence['linearMemoryLimitBytes'] != 65536 ||
        evidence['linearMemoryBytesObserved'] != 65536 ||
        evidence['epochDeadlineTicks'] != 1 ||
        evidence['epochIncrementAfterMilliseconds'] != 100 ||
        evidence['wasiEnabled'] != false ||
        imports is! List ||
        imports.length != 1 ||
        imports.single != 'larenor.current_home_resource_count()->i32') {
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
      artifactSha256: evidence['artifactSha256'] as String,
      fuelConsumed: fuelConsumed,
      linearMemoryBytesObserved: evidence['linearMemoryBytesObserved'] as int,
    );
  }

  final String pluginId, artifactSha256;
  final int pluginRevision,
      resourceCount,
      fuelConsumed,
      linearMemoryBytesObserved;
  final DateTime generatedAt;
}
