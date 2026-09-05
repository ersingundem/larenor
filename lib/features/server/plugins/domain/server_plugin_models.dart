import '../../domain/server_models.dart';

const pluginServiceIds = {
  'jellyfin',
  'seerr',
  'sonarr',
  'radarr',
  'qbittorrent',
  'music_assistant',
};
const pluginPlatforms = {'linux/amd64', 'linux/arm64'};
const pluginSettingNames = {
  'instanceName',
  'dataRootId',
  'webPort',
  'torrentPort',
  'libraryRootId',
  'mediaRootId',
  'musicRootId',
};
const _profileKeys = {
  'security',
  'network',
  'mounts',
  'ports',
  'tmpfs',
  'environment',
  'resources',
  'health',
  'warnings',
};

Never _invalid() => throw const LarenorServerException('invalid_response');

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  final result = serverObject(value);
  if (result.length != keys.length || !keys.every(result.containsKey)) {
    _invalid();
  }
  return result;
}

String _string(Object? value, {int max = 240, String? pattern}) {
  if (value is! String ||
      value.isEmpty ||
      value.length > max ||
      RegExp(r'[\x00-\x1f\x7f\uD800-\uDFFF]').hasMatch(value) ||
      (pattern != null && !RegExp('^(?:$pattern)\$').hasMatch(value))) {
    _invalid();
  }
  return value;
}

String _one(Object? value, Set<String> allowed) {
  if (value is! String || !allowed.contains(value)) _invalid();
  return value;
}

int _integer(Object? value, int min, int max) {
  if (value is! int || value < min || value > max) _invalid();
  return value;
}

bool _bool(Object? value) {
  if (value is! bool) _invalid();
  return value;
}

List<T> _list<T>(Object? value, int min, int max, T Function(Object?) parse) {
  if (value is! List || value.length < min || value.length > max) _invalid();
  return List.unmodifiable(value.map(parse));
}

void _unique(Iterable<Object?> values) {
  if (values.toSet().length != values.length) _invalid();
}

String _digest(Object? value) =>
    _string(value, max: 64, pattern: r'[0-9a-f]{64}');
String _imageDigest(Object? value) =>
    _string(value, max: 71, pattern: r'sha256:[0-9a-f]{64}');
String _root(Object? value) =>
    _string(value, max: 32, pattern: r'[a-z][a-z0-9_-]{0,31}');
String _repository(Object? value) =>
    _string(value, pattern: r'ghcr\.io/[a-z0-9-]+/[a-z0-9-]+');
String _tag(Object? value) =>
    _string(value, max: 128, pattern: r'[A-Za-z0-9_][A-Za-z0-9._-]{0,127}');
String _url(Object? value) {
  final text = _string(value, max: 300, pattern: r'https://[A-Za-z0-9._/-]+');
  final uri = Uri.tryParse(text);
  if (uri == null ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    _invalid();
  }
  return text;
}

enum PluginSettingKind { slug, rootId, optionalRootId, port }

class PluginSettingSpec {
  PluginSettingSpec._(this.name, this.kind, this.defaultValue);
  final String name;
  final PluginSettingKind kind;
  final Object? defaultValue;

  factory PluginSettingSpec.fromJson(Object? value) {
    final map = _object(value, {
      'name',
      'kind',
      'default',
      'minimum',
      'maximum',
    });
    final name = _one(map['name'], pluginSettingNames);
    final kind = switch (map['kind']) {
      'slug' => PluginSettingKind.slug,
      'root_id' => PluginSettingKind.rootId,
      'optional_root_id' => PluginSettingKind.optionalRootId,
      'port' => PluginSettingKind.port,
      _ => _invalid(),
    };
    if (kind == PluginSettingKind.port
        ? map['minimum'] is! int ||
              map['maximum'] is! int ||
              map['minimum'] != 1024 ||
              map['maximum'] != 65535
        : map['minimum'] != null || map['maximum'] != null) {
      _invalid();
    }
    final spec = PluginSettingSpec._(name, kind, map['default']);
    if (!spec.accepts(spec.defaultValue)) _invalid();
    // Field semantics stay fixed; a Server cannot turn a port into free text.
    final expected = switch (name) {
      'instanceName' => PluginSettingKind.slug,
      'webPort' || 'torrentPort' => PluginSettingKind.port,
      'mediaRootId' || 'musicRootId' => PluginSettingKind.optionalRootId,
      _ => PluginSettingKind.rootId,
    };
    if (kind != expected) _invalid();
    return spec;
  }

  bool accepts(Object? value) => switch (kind) {
    PluginSettingKind.port => value is int && value >= 1024 && value <= 65535,
    PluginSettingKind.optionalRootId when value == null => true,
    PluginSettingKind.slug =>
      value is String && RegExp(r'^[a-z][a-z0-9-]{0,39}$').hasMatch(value),
    _ => value is String && RegExp(r'^[a-z][a-z0-9_-]{0,31}$').hasMatch(value),
  };

  Object? parseInput(String text) => switch (kind) {
    PluginSettingKind.port => int.tryParse(text.trim()),
    PluginSettingKind.optionalRootId when text.trim().isEmpty => null,
    _ => text.trim(),
  };
}

class PluginImage {
  PluginImage._(this.platform, this.digest, this.configDigest);
  final String platform, digest, configDigest;
  factory PluginImage.fromJson(Object? value) {
    final map = _object(value, {'platform', 'digest', 'configDigest'});
    return PluginImage._(
      _one(map['platform'], pluginPlatforms),
      _imageDigest(map['digest']),
      _imageDigest(map['configDigest']),
    );
  }
}

class PluginSecurity {
  PluginSecurity._(this.user, this.capAdd, this.init);
  final String user;
  final List<String> capAdd;
  final bool init;
  factory PluginSecurity.fromJson(Object? value) {
    final map = _object(value, {
      'user',
      'privileged',
      'capDrop',
      'capAdd',
      'noNewPrivileges',
      'init',
    });
    if (_bool(map['privileged']) || !_bool(map['noNewPrivileges'])) _invalid();
    _list(map['capDrop'], 1, 1, (value) => _one(value, {'ALL'}));
    return PluginSecurity._(
      _one(map['user'], {'1000:1000', '0:0'}),
      _list(map['capAdd'], 0, 1, (value) => _one(value, {'NET_BIND_SERVICE'})),
      _bool(map['init']),
    );
  }
}

class PluginListener {
  PluginListener._(this.protocol, this.port, this.purpose);
  final String protocol, purpose;
  final int port;
  factory PluginListener.fromJson(Object? value) {
    final map = _object(value, {'protocol', 'port', 'purpose'});
    return PluginListener._(
      _one(map['protocol'], {'tcp', 'udp'}),
      _integer(map['port'], 1, 65535),
      _one(map['purpose'], {
        'web',
        'stream',
        'torrent',
        'airplay_ptp_event',
        'airplay_ptp_general',
      }),
    );
  }
}

class PluginNetwork {
  PluginNetwork._(this.mode, this.listeners, this.dynamicReceiverPorts);
  final String mode;
  final List<PluginListener> listeners;
  final bool dynamicReceiverPorts;
  factory PluginNetwork.fromJson(Object? value) {
    final map = _object(value, {'mode', 'listeners', 'dynamicReceiverPorts'});
    return PluginNetwork._(
      _one(map['mode'], {'bridge', 'host'}),
      _list(map['listeners'], 1, 8, PluginListener.fromJson),
      _bool(map['dynamicReceiverPorts']),
    );
  }
}

class PluginPort {
  PluginPort._(this.protocol, this.hostPort, this.containerPort);
  final String protocol;
  final int hostPort, containerPort;
  factory PluginPort.fromJson(Object? value) {
    final map = _object(value, {
      'protocol',
      'hostIp',
      'hostPort',
      'containerPort',
    });
    _one(map['hostIp'], {'0.0.0.0'});
    return PluginPort._(
      _one(map['protocol'], {'tcp', 'udp'}),
      _integer(map['hostPort'], 1024, 65535),
      _integer(map['containerPort'], 1, 65535),
    );
  }
}

class PluginMount {
  PluginMount._(
    this.kind,
    this.rootId,
    this.relativePath,
    this.target,
    this.readOnly,
  );
  final String kind, rootId, relativePath, target;
  final bool readOnly;
  factory PluginMount.fromJson(Object? value) {
    final map = _object(value, {
      'kind',
      'rootId',
      'relativePath',
      'target',
      'readOnly',
    });
    final kind = _one(map['kind'], {'managed_appdata', 'approved_library'});
    final path = map['relativePath'];
    if (path is! String ||
        !RegExp(r'^(?:[a-z][a-z0-9-]{0,39}/(?:config|cache|data))?$')
            .hasMatch(path)) {
      _invalid();
    }
    final readOnly = _bool(map['readOnly']);
    if (kind == 'managed_appdata'
        ? path.isEmpty || readOnly
        : path.isNotEmpty) {
      _invalid();
    }
    return PluginMount._(
      kind,
      _root(map['rootId']),
      path,
      _string(map['target'], max: 81, pattern: r'/[a-z][a-z0-9_/]{0,79}'),
      readOnly,
    );
  }
}

class PluginTmpfs {
  PluginTmpfs._(this.target, this.sizeMiB, this.uid, this.gid, this.executable);
  final String target;
  final int sizeMiB, uid, gid;
  final bool executable;
  factory PluginTmpfs.fromJson(Object? value) {
    final map = _object(value, {
      'target',
      'sizeMiB',
      'uid',
      'gid',
      'executable',
    });
    final uid = _integer(map['uid'], 0, 1000),
        gid = _integer(map['gid'], 0, 1000);
    if (!{0, 1000}.contains(uid) || !{0, 1000}.contains(gid)) _invalid();
    return PluginTmpfs._(
      _one(map['target'], {'/tmp', '/run'}),
      _integer(map['sizeMiB'], 16, 512),
      uid,
      gid,
      _bool(map['executable']),
    );
  }
}

class PluginEnvironment {
  PluginEnvironment._(this.name, this.value);
  final String name, value;
  factory PluginEnvironment.fromJson(Object? value) {
    final map = _object(value, {'name', 'value'});
    return PluginEnvironment._(
      _one(map['name'], {
        'TZ',
        'PORT',
        'WEBUI_PORT',
        'TORRENTING_PORT',
        'LOG_LEVEL',
      }),
      _string(map['value'], max: 80, pattern: r'[A-Za-z0-9/_-]+'),
    );
  }
}

class PluginResources {
  PluginResources._(
    this.memoryMiB,
    this.cpuMillis,
    this.pidsLimit,
    this.minimumDiskMiB,
  );
  final int memoryMiB, cpuMillis, pidsLimit, minimumDiskMiB;
  factory PluginResources.fromJson(Object? value) {
    final map = _object(value, {
      'memoryMiB',
      'cpuMillis',
      'pidsLimit',
      'minimumDiskMiB',
    });
    return PluginResources._(
      _integer(map['memoryMiB'], 128, 16384),
      _integer(map['cpuMillis'], 100, 16000),
      _integer(map['pidsLimit'], 32, 4096),
      _integer(map['minimumDiskMiB'], 1024, 1048576),
    );
  }
}

class PluginHealth {
  PluginHealth._(this.profile, this.path, this.port);
  final String profile, path;
  final int port;
  factory PluginHealth.fromJson(Object? value) {
    final map = _object(value, {'profile', 'path', 'port'});
    return PluginHealth._(
      _one(map['profile'], {
        'jellyfin_public',
        'seerr_public',
        'sonarr_public',
        'radarr_public',
        'qbittorrent_web',
        'music_assistant_info',
      }),
      _string(map['path'], pattern: r'/[A-Za-z0-9/_-]*'),
      _integer(map['port'], 1, 65535),
    );
  }
}

class PluginEffects {
  PluginEffects._(Map<String, dynamic> map)
    : security = PluginSecurity.fromJson(map['security']),
      network = PluginNetwork.fromJson(map['network']),
      mounts = _list(map['mounts'], 1, 3, PluginMount.fromJson),
      ports = _list(map['ports'], 0, 3, PluginPort.fromJson),
      tmpfs = _list(map['tmpfs'], 0, 2, PluginTmpfs.fromJson),
      environment = _list(map['environment'], 0, 4, PluginEnvironment.fromJson),
      resources = PluginResources.fromJson(map['resources']),
      health = PluginHealth.fromJson(map['health']),
      warnings = _list(map['warnings'], 0, 12, (value) => _string(value)) {
    _unique(mounts.map((value) => value.target));
    _unique(environment.map((value) => value.name));
  }
  final PluginSecurity security;
  final PluginNetwork network;
  final List<PluginMount> mounts;
  final List<PluginPort> ports;
  final List<PluginTmpfs> tmpfs;
  final List<PluginEnvironment> environment;
  final PluginResources resources;
  final PluginHealth health;
  final List<String> warnings;

  void _validateService(String service) {
    if ((network.mode == 'host' &&
            (service != 'music_assistant' || ports.isNotEmpty)) ||
        (service != 'music_assistant' &&
            (security.capAdd.isNotEmpty || security.user != '1000:1000'))) {
      _invalid();
    }
  }
}

class PluginManifest {
  PluginManifest._(Map<String, dynamic> map)
    : serviceId = _one(map['serviceId'], pluginServiceIds),
      integrationRole = _one(map['integrationRole'], {
        'managed_service',
        'internal_engine',
      }),
      distributionId = _one(map['distributionId'], {'upstream', 'linuxserver'}),
      displayName = _string(map['displayName']),
      version = _string(
        map['version'],
        max: 80,
        pattern: r'[A-Za-z0-9._-]{1,80}',
      ),
      upstreamRepository = _url(map['upstreamRepository']),
      sourceRepository = _url(map['sourceRepository']),
      sourceRevision = _string(
        map['sourceRevision'],
        max: 40,
        pattern: r'[0-9a-f]{40}',
      ),
      releaseUrl = _url(map['releaseUrl']),
      license = _string(map['license']),
      licenseUrl = _url(map['licenseUrl']),
      distributionLicense = _string(map['distributionLicense']),
      documentationUrls = _list(map['documentationUrls'], 1, 5, _url),
      repository = _repository(map['repository']),
      tag = _tag(map['tag']),
      indexDigest = _imageDigest(map['indexDigest']),
      images = _list(map['images'], 1, 2, PluginImage.fromJson),
      settings = _list(map['settings'], 2, 6, PluginSettingSpec.fromJson),
      effects = PluginEffects._(map) {
    _integer(map['manifestVersion'], 1, 1);
    _integer(map['configSchemaVersion'], 1, 1);
    _one(map['dataSchemaVersion'], {'upstream_managed_unverified'});
    _one(map['verifiedAt'], {'2026-09-05'});
    if (_bool(map['installable'])) _invalid();
    _unique(images.map((value) => value.platform));
    _unique(settings.map((value) => value.name));
    if (!settings.any((spec) => spec.name == 'instanceName') ||
        !settings.any((spec) => spec.name == 'dataRootId')) {
      _invalid();
    }
    effects._validateService(serviceId);
    if ((serviceId == 'music_assistant') !=
        (integrationRole == 'internal_engine')) {
      _invalid();
    }
  }
  factory PluginManifest.fromJson(Object? value) => PluginManifest._(
    _object(value, {
      'manifestVersion',
      'configSchemaVersion',
      'dataSchemaVersion',
      'serviceId',
      'integrationRole',
      'distributionId',
      'displayName',
      'version',
      'upstreamRepository',
      'sourceRepository',
      'sourceRevision',
      'releaseUrl',
      'license',
      'licenseUrl',
      'distributionLicense',
      'documentationUrls',
      'verifiedAt',
      'repository',
      'tag',
      'indexDigest',
      'images',
      'installable',
      'settings',
      ..._profileKeys,
    }),
  );
  final String serviceId,
      integrationRole,
      distributionId,
      displayName,
      version,
      upstreamRepository,
      sourceRepository,
      sourceRevision,
      releaseUrl,
      license,
      licenseUrl,
      distributionLicense,
      repository,
      tag,
      indexDigest;
  final List<String> documentationUrls;
  final List<PluginImage> images;
  final List<PluginSettingSpec> settings;
  final PluginEffects effects;
  bool get installable => false;
  Map<String, Object?> get defaultSettings => Map.unmodifiable({
    for (final spec in settings) spec.name: spec.defaultValue,
  });
  bool acceptsSettings(Map<String, Object?> values) =>
      values.length == settings.length &&
      settings.every(
        (spec) =>
            values.containsKey(spec.name) && spec.accepts(values[spec.name]),
      ) &&
      (serviceId != 'qbittorrent' ||
          values['webPort'] != values['torrentPort']);
}

class PluginCatalogEntry {
  PluginCatalogEntry._(this.catalogDigest, this.manifestDigest, this.manifest);
  final String catalogDigest, manifestDigest;
  final PluginManifest manifest;
  factory PluginCatalogEntry.fromJson(Object? value) {
    final map = _object(value, {'catalogDigest', 'manifestDigest', 'manifest'});
    return PluginCatalogEntry._(
      _digest(map['catalogDigest']),
      _digest(map['manifestDigest']),
      PluginManifest.fromJson(map['manifest']),
    );
  }
}

class ServerPluginCatalog {
  ServerPluginCatalog._(this.digest, this.entries);
  final String digest;
  final List<PluginCatalogEntry> entries;
  bool get workerAvailable => false;
  factory ServerPluginCatalog.fromJson(Object? value) {
    final map = _object(value, {'catalogDigest', 'entries', 'worker'});
    final digest = _digest(map['catalogDigest']);
    final worker = _object(map['worker'], {'available', 'platform', 'reason'});
    if (_bool(worker['available']) ||
        worker['platform'] != null ||
        worker['reason'] != 'worker_not_configured') {
      _invalid();
    }
    final entries = _list(map['entries'], 6, 6, PluginCatalogEntry.fromJson);
    _unique(entries.map((entry) => entry.manifest.serviceId));
    if (entries.any((entry) => entry.catalogDigest != digest)) _invalid();
    return ServerPluginCatalog._(digest, entries);
  }
}

class PluginSelectedImage {
  PluginSelectedImage._(Map<String, dynamic> map)
    : repository = _repository(map['repository']),
      tag = _tag(map['tag']),
      platform = _one(map['platform'], pluginPlatforms),
      digest = _imageDigest(map['digest']),
      indexDigest = _imageDigest(map['indexDigest']),
      reference = _string(map['reference'], max: 450) {
    if (reference != '$repository:$tag@$digest') _invalid();
  }
  factory PluginSelectedImage.fromJson(Object? value) => PluginSelectedImage._(
    _object(value, {
      'repository',
      'tag',
      'platform',
      'digest',
      'indexDigest',
      'reference',
    }),
  );
  final String repository, tag, platform, digest, indexDigest, reference;
}

class PluginInstallPlan {
  PluginInstallPlan._(Map<String, dynamic> map)
    : serviceId = _one(map['serviceId'], pluginServiceIds),
      integrationRole = _one(map['integrationRole'], {
        'managed_service',
        'internal_engine',
      }),
      distributionId = _one(map['distributionId'], {'upstream', 'linuxserver'}),
      instanceName = _string(
        map['instanceName'],
        max: 40,
        pattern: r'[a-z][a-z0-9-]{0,39}',
      ),
      catalogDigest = _digest(map['catalogDigest']),
      manifestDigest = _digest(map['manifestDigest']),
      planHash = _digest(map['planHash']),
      image = PluginSelectedImage.fromJson(map['image']),
      effects = PluginEffects._(map),
      settings = _settings(map['settings']) {
    _integer(map['schemaVersion'], 1, 1);
    if (_bool(map['installable'])) _invalid();
    final blockers = _list(
      map['blockers'],
      2,
      2,
      (value) => _one(value, {'worker_unverified', 'host_preflight_required'}),
    );
    if (blockers[0] != 'worker_unverified' ||
        blockers[1] != 'host_preflight_required') {
      _invalid();
    }
    effects._validateService(serviceId);
    if ((serviceId == 'music_assistant') !=
        (integrationRole == 'internal_engine')) {
      _invalid();
    }
    if (settings['instanceName'] != instanceName) _invalid();
  }
  factory PluginInstallPlan.fromJson(Object? value) => PluginInstallPlan._(
    _object(value, {
      'schemaVersion',
      'serviceId',
      'integrationRole',
      'distributionId',
      'instanceName',
      'catalogDigest',
      'manifestDigest',
      'planHash',
      'installable',
      'blockers',
      'settings',
      'image',
      ..._profileKeys,
    }),
  );
  final String serviceId,
      integrationRole,
      distributionId,
      instanceName,
      catalogDigest,
      manifestDigest,
      planHash;
  final PluginSelectedImage image;
  final PluginEffects effects;
  final Map<String, Object?> settings;
  bool get installable => false;

  static Map<String, Object?> _settings(Object? value) {
    final items = _list(
      value,
      2,
      6,
      (value) => _object(value, {'name', 'value'}),
    );
    _unique(items.map((map) => map['name']));
    final values = <String, Object?>{};
    for (final item in items) {
      final name = _one(item['name'], pluginSettingNames);
      final value = item['value'];
      if (value != null && value is! String && value is! int) _invalid();
      values[name] = value;
    }
    return Map.unmodifiable(values);
  }

  bool matches(
    PluginCatalogEntry entry,
    String platform,
    Map<String, Object?> requested,
  ) {
    final manifest = entry.manifest;
    return catalogDigest == entry.catalogDigest &&
        manifestDigest == entry.manifestDigest &&
        serviceId == manifest.serviceId &&
        integrationRole == manifest.integrationRole &&
        distributionId == manifest.distributionId &&
        image.platform == platform &&
        image.repository == manifest.repository &&
        image.tag == manifest.tag &&
        image.indexDigest == manifest.indexDigest &&
        manifest.images.any(
          (item) => item.platform == platform && item.digest == image.digest,
        ) &&
        manifest.acceptsSettings(settings) &&
        requested.length == settings.length &&
        requested.entries.every(
          (item) =>
              settings.containsKey(item.key) &&
              settings[item.key] == item.value,
        ) &&
        _effectsMatch(manifest, requested);
  }

  bool _effectsMatch(PluginManifest manifest, Map<String, Object?> values) {
    final original = manifest.effects;
    bool same<T>(List<T> first, List<T> second) =>
        first.length == second.length &&
        List.generate(
          first.length,
          (index) => first[index] == second[index],
        ).every((value) => value);
    final qbit = serviceId == 'qbittorrent';
    final expectedMounts = [
      for (final mount in original.mounts)
        (
          mount.kind,
          mount.kind == 'managed_appdata'
              ? values['dataRootId']
              : values['libraryRootId'],
          mount.kind == 'managed_appdata'
              ? '${values['instanceName']}/${mount.relativePath.split('/').last}'
              : '',
          mount.target,
          mount.readOnly,
        ),
      if ((values['mediaRootId'] ?? values['musicRootId']) != null)
        (
          'approved_library',
          values['mediaRootId'] ?? values['musicRootId'],
          '',
          '/media',
          true,
        ),
    ];
    final expectedPorts = qbit
        ? [
            ('tcp', values['webPort'], values['webPort']),
            ('tcp', values['torrentPort'], values['torrentPort']),
            ('udp', values['torrentPort'], values['torrentPort']),
          ]
        : [
            for (var index = 0; index < original.ports.length; index++)
              (
                original.ports[index].protocol,
                index == 0 ? values['webPort'] : original.ports[index].hostPort,
                original.ports[index].containerPort,
              ),
          ];
    final expectedEnvironment = {
      for (final item in original.environment) item.name: item.value,
      if (qbit) 'WEBUI_PORT': '${values['webPort']}',
      if (qbit) 'TORRENTING_PORT': '${values['torrentPort']}',
    };
    return effects.security.user == original.security.user &&
        effects.security.init == original.security.init &&
        same(effects.security.capAdd, original.security.capAdd) &&
        effects.network.mode == original.network.mode &&
        effects.network.dynamicReceiverPorts ==
            original.network.dynamicReceiverPorts &&
        same(
          effects.network.listeners
              .map((item) => (item.protocol, item.port, item.purpose))
              .toList(),
          original.network.listeners
              .map(
                (item) => (
                  item.protocol,
                  qbit
                      ? values[item.purpose == 'web'
                            ? 'webPort'
                            : 'torrentPort']
                      : item.port,
                  item.purpose,
                ),
              )
              .toList(),
        ) &&
        same(
          effects.mounts
              .map(
                (item) => (
                  item.kind,
                  item.rootId,
                  item.relativePath,
                  item.target,
                  item.readOnly,
                ),
              )
              .toList(),
          expectedMounts,
        ) &&
        same(
          effects.ports
              .map((item) => (item.protocol, item.hostPort, item.containerPort))
              .toList(),
          expectedPorts,
        ) &&
        same(
          effects.tmpfs
              .map(
                (item) => (
                  item.target,
                  item.sizeMiB,
                  item.uid,
                  item.gid,
                  item.executable,
                ),
              )
              .toList(),
          original.tmpfs
              .map(
                (item) => (
                  item.target,
                  item.sizeMiB,
                  item.uid,
                  item.gid,
                  item.executable,
                ),
              )
              .toList(),
        ) &&
        effects.environment.length == expectedEnvironment.length &&
        effects.environment.every(
          (item) => expectedEnvironment[item.name] == item.value,
        ) &&
        effects.resources.memoryMiB == original.resources.memoryMiB &&
        effects.resources.cpuMillis == original.resources.cpuMillis &&
        effects.resources.pidsLimit == original.resources.pidsLimit &&
        effects.resources.minimumDiskMiB == original.resources.minimumDiskMiB &&
        effects.health.profile == original.health.profile &&
        effects.health.path == original.health.path &&
        effects.health.port ==
            (qbit ? values['webPort'] : original.health.port) &&
        same(effects.warnings, original.warnings);
  }
}

class ServerPluginPreview {
  ServerPluginPreview._(this.id, this.createdAt, this.expiresAt, this.plan);
  final String id;
  final DateTime createdAt, expiresAt;
  final PluginInstallPlan plan;
  int get revision => 1;
  bool expired(DateTime now) => !now.toUtc().isBefore(expiresAt);
  factory ServerPluginPreview.fromJson(Object? value) {
    final map = _object(value, {
      'id',
      'revision',
      'createdAt',
      'expiresAt',
      'plan',
    });
    _integer(map['revision'], 1, 1);
    DateTime date(Object? value) {
      final text = _string(
        value,
        max: 40,
        pattern:
            r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|\+00:00)',
      );
      final parsed = DateTime.tryParse(text);
      if (parsed == null ||
          !parsed.isUtc ||
          text.substring(0, 19) != parsed.toIso8601String().substring(0, 19)) {
        _invalid();
      }
      return parsed;
    }

    final created = date(map['createdAt']), expires = date(map['expiresAt']);
    if (expires.difference(created) != const Duration(minutes: 10)) _invalid();
    return ServerPluginPreview._(
      _string(map['id'], max: 32, pattern: r'[0-9a-f]{32}'),
      created,
      expires,
      PluginInstallPlan.fromJson(map['plan']),
    );
  }
}
