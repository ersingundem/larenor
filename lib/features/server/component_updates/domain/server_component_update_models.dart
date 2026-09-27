import '../../domain/server_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  final result = serverObject(value);
  if (result.length != keys.length || !keys.every(result.containsKey)) {
    _invalid();
  }
  return result;
}

String _string(Object? value, RegExp pattern, {int max = 320}) {
  if (value is! String ||
      value.isEmpty ||
      value.length > max ||
      !pattern.hasMatch(value)) {
    _invalid();
  }
  return value;
}

String _digest(Object? value) =>
    _string(value, RegExp(r'^[0-9a-f]{64}$'), max: 64);
String _identity(Object? value) =>
    _string(value, RegExp(r'^[0-9a-f]{32}$'), max: 32);
String _version(Object? value) =>
    _string(value, RegExp(r'^[A-Za-z0-9._-]{1,80}$'), max: 80);
String _url(Object? value) =>
    _string(value, RegExp(r'^https://[A-Za-z0-9._/-]+$'), max: 300);

List<String> _strings(Object? value, RegExp pattern, {int max = 64}) {
  if (value is! List || value.length > max) _invalid();
  final result = value
      .map((item) => _string(item, pattern))
      .toList(growable: false);
  if (result.toSet().length != result.length ||
      result.join('\u0000') !=
          (List<String>.of(result)..sort()).join('\u0000')) {
    _invalid();
  }
  return List.unmodifiable(result);
}

final _permission = RegExp(r'^[a-z][a-z0-9_]*(?::[A-Za-z0-9._/:@=-]+)+$');
const serverComponentReleasePreferenceModes = {
  'stable_only',
  'manual_review',
  'disabled',
};

final class ServerComponentReleasePreference {
  const ServerComponentReleasePreference({
    required this.coreId,
    required this.homeId,
    required this.serviceId,
    required this.revision,
    required this.mode,
    required this.requireUpstreamSignature,
  });

  factory ServerComponentReleasePreference.fromJson(Object? raw) {
    final json = _object(raw, {
      'schemaVersion',
      'coreId',
      'homeId',
      'serviceId',
      'revision',
      'mode',
      'requireUpstreamSignature',
    });
    final revision = json['revision'];
    final mode = json['mode'];
    if (json['schemaVersion'] != 1 ||
        revision is! int ||
        revision < 0 ||
        revision > 0x7fffffffffffffff ||
        mode is! String ||
        !serverComponentReleasePreferenceModes.contains(mode) ||
        json['requireUpstreamSignature'] is! bool) {
      _invalid();
    }
    return ServerComponentReleasePreference(
      coreId: _identity(json['coreId']),
      homeId: _identity(json['homeId']),
      serviceId: _string(
        json['serviceId'],
        RegExp(r'^[a-z][a-z0-9_]{0,63}$'),
        max: 64,
      ),
      revision: revision,
      mode: mode,
      requireUpstreamSignature: json['requireUpstreamSignature'] as bool,
    );
  }

  final String coreId;
  final String homeId;
  final String serviceId;
  final int revision;
  final String mode;
  final bool requireUpstreamSignature;
}

final class ServerComponentSignature {
  const ServerComponentSignature({
    required this.status,
    required this.kind,
    required this.issuer,
    required this.subject,
    required this.bundleDigest,
  });

  factory ServerComponentSignature.fromJson(Object? raw) {
    final json = _object(raw, {
      'status',
      'kind',
      'issuer',
      'subject',
      'bundleDigest',
    });
    final status = json['status'];
    final kind = json['kind'];
    if (status != 'verified' && status != 'unavailable') _invalid();
    if (kind != 'sigstore_bundle' && kind != 'upstream_unavailable') {
      _invalid();
    }
    final verified = status == 'verified';
    final issuer = json['issuer'];
    final subject = json['subject'];
    final bundle = json['bundleDigest'];
    if (verified) {
      if (kind != 'sigstore_bundle' ||
          issuer is! String ||
          subject is! String) {
        _invalid();
      }
      _string(issuer, RegExp(r'^[^\x00-\x1f\x7f]{1,300}$'), max: 300);
      _string(subject, RegExp(r'^[^\x00-\x1f\x7f]{1,300}$'), max: 300);
      _digest(bundle);
    } else if (kind != 'upstream_unavailable' ||
        issuer != null ||
        subject != null ||
        bundle != null) {
      _invalid();
    }
    return ServerComponentSignature(
      status: status as String,
      kind: kind as String,
      issuer: issuer as String?,
      subject: subject as String?,
      bundleDigest: bundle as String?,
    );
  }

  final String status;
  final String kind;
  final String? issuer;
  final String? subject;
  final String? bundleDigest;
  bool get verified => status == 'verified';
}

final class ServerComponentRelease {
  const ServerComponentRelease({
    required this.serviceId,
    required this.version,
    required this.publisher,
    required this.upstreamRepository,
    required this.sourceRepository,
    required this.releaseUrl,
    required this.repository,
    required this.platform,
    required this.signature,
    required this.catalogDigest,
    required this.manifestDigest,
    required this.sourceRevision,
    required this.imageDigest,
    required this.imageConfigDigest,
  });

  factory ServerComponentRelease.fromJson(Object? raw) {
    final json = _object(raw, {
      'schemaVersion',
      'serviceId',
      'integrationRole',
      'distributionId',
      'version',
      'publisher',
      'upstreamRepository',
      'sourceRepository',
      'releaseUrl',
      'repository',
      'platform',
      'signature',
      'build',
    });
    if (json['schemaVersion'] != 1 ||
        !const {
          'managed_service',
          'internal_engine',
        }.contains(json['integrationRole']) ||
        !const {'upstream', 'linuxserver'}.contains(json['distributionId']) ||
        !const {'linux/amd64', 'linux/arm64'}.contains(json['platform'])) {
      _invalid();
    }
    final build = _object(json['build'], {
      'kind',
      'catalogDigest',
      'manifestDigest',
      'sourceRevision',
      'imageDigest',
      'imageConfigDigest',
    });
    if (build['kind'] != 'packaged_catalog_pin') _invalid();
    return ServerComponentRelease(
      serviceId: _string(
        json['serviceId'],
        RegExp(r'^[a-z][a-z0-9_]{0,63}$'),
        max: 64,
      ),
      version: _version(json['version']),
      publisher: _string(
        json['publisher'],
        RegExp(r'^[A-Za-z0-9._-]{1,240}$'),
        max: 240,
      ),
      upstreamRepository: _url(json['upstreamRepository']),
      sourceRepository: _url(json['sourceRepository']),
      releaseUrl: _url(json['releaseUrl']),
      repository: _string(
        json['repository'],
        RegExp(r'^ghcr\.io/[a-z0-9-]+/[a-z0-9-]+$'),
        max: 240,
      ),
      platform: json['platform'] as String,
      signature: ServerComponentSignature.fromJson(json['signature']),
      catalogDigest: _digest(build['catalogDigest']),
      manifestDigest: _digest(build['manifestDigest']),
      sourceRevision: _string(
        build['sourceRevision'],
        RegExp(r'^[0-9a-f]{40}$'),
        max: 40,
      ),
      imageDigest: _string(
        build['imageDigest'],
        RegExp(r'^sha256:[0-9a-f]{64}$'),
        max: 71,
      ),
      imageConfigDigest: _string(
        build['imageConfigDigest'],
        RegExp(r'^sha256:[0-9a-f]{64}$'),
        max: 71,
      ),
    );
  }

  final String serviceId;
  final String version;
  final String publisher;
  final String upstreamRepository;
  final String sourceRepository;
  final String releaseUrl;
  final String repository;
  final String platform;
  final ServerComponentSignature signature;
  final String catalogDigest;
  final String manifestDigest;
  final String sourceRevision;
  final String imageDigest;
  final String imageConfigDigest;
}

final class ServerComponentSchema {
  const ServerComponentSchema(this.configVersion, this.dataVersion);

  factory ServerComponentSchema.fromJson(Object? raw) {
    final json = _object(raw, {'configSchemaVersion', 'dataSchemaVersion'});
    final config = json['configSchemaVersion'];
    if (config is! int || config < 1 || config > 0x7fffffff) _invalid();
    return ServerComponentSchema(config, _version(json['dataSchemaVersion']));
  }

  final int configVersion;
  final String dataVersion;
}

final class ServerInstalledComponentUpdate {
  const ServerInstalledComponentUpdate({
    required this.installationId,
    required this.sourceDigest,
    required this.release,
    required this.permissions,
    required this.schema,
  });

  factory ServerInstalledComponentUpdate.fromJson(Object? raw) {
    final json = _object(raw, {
      'schemaVersion',
      'installationId',
      'sourceDigest',
      'current',
      'permissions',
      'componentSchema',
    });
    if (json['schemaVersion'] != 1) _invalid();
    final permissions = _object(json['permissions'], {'claims'});
    return ServerInstalledComponentUpdate(
      installationId: _identity(json['installationId']),
      sourceDigest: _digest(json['sourceDigest']),
      release: ServerComponentRelease.fromJson(json['current']),
      permissions: _strings(permissions['claims'], _permission),
      schema: ServerComponentSchema.fromJson(json['componentSchema']),
    );
  }

  final String installationId;
  final String sourceDigest;
  final ServerComponentRelease release;
  final List<String> permissions;
  final ServerComponentSchema schema;
}

final class ServerComponentUpdateReview {
  const ServerComponentUpdateReview({
    required this.installationId,
    required this.reviewDigest,
    required this.current,
    required this.target,
    required this.addedPermissions,
    required this.removedPermissions,
    required this.retainedPermissions,
    required this.migrationRequired,
    required this.rollbackSnapshotRequired,
    required this.blockers,
    required this.approvalRequired,
    required this.applyAvailable,
  });

  factory ServerComponentUpdateReview.fromJson(Object? raw) {
    final json = _object(raw, {
      'schemaVersion',
      'coreId',
      'homeId',
      'installationId',
      'reviewDigest',
      'current',
      'target',
      'permissions',
      'migration',
      'blockers',
      'approvalRequired',
      'applyAvailable',
    });
    if (json['schemaVersion'] != 1 ||
        json['approvalRequired'] is! bool ||
        json['applyAvailable'] is! bool ||
        json['applyAvailable'] != false) {
      _invalid();
    }
    _identity(json['coreId']);
    _identity(json['homeId']);
    final permissions = _object(json['permissions'], {
      'added',
      'removed',
      'retained',
    });
    final migration = _object(json['migration'], {
      'current',
      'target',
      'migrationRequired',
      'rollbackSnapshotRequired',
      'state',
    });
    ServerComponentSchema.fromJson(migration['current']);
    ServerComponentSchema.fromJson(migration['target']);
    if (migration['migrationRequired'] is! bool ||
        migration['rollbackSnapshotRequired'] is! bool ||
        !const {
          'not_required',
          'snapshot_required',
        }.contains(migration['state'])) {
      _invalid();
    }
    final blockerPattern = RegExp(r'^[a-z][a-z0-9_]{2,63}$');
    return ServerComponentUpdateReview(
      installationId: _identity(json['installationId']),
      reviewDigest: _digest(json['reviewDigest']),
      current: ServerComponentRelease.fromJson(json['current']),
      target: ServerComponentRelease.fromJson(json['target']),
      addedPermissions: _strings(permissions['added'], _permission),
      removedPermissions: _strings(permissions['removed'], _permission),
      retainedPermissions: _strings(permissions['retained'], _permission),
      migrationRequired: migration['migrationRequired'] as bool,
      rollbackSnapshotRequired: migration['rollbackSnapshotRequired'] as bool,
      blockers: _strings(json['blockers'], blockerPattern, max: 10),
      approvalRequired: json['approvalRequired'] as bool,
      applyAvailable: json['applyAvailable'] as bool,
    );
  }

  final String installationId;
  final String reviewDigest;
  final ServerComponentRelease current;
  final ServerComponentRelease target;
  final List<String> addedPermissions;
  final List<String> removedPermissions;
  final List<String> retainedPermissions;
  final bool migrationRequired;
  final bool rollbackSnapshotRequired;
  final List<String> blockers;
  final bool approvalRequired;
  final bool applyAvailable;

  bool get isCurrent => blockers.contains('same_release');
}

final class ServerComponentUpdateInventory {
  const ServerComponentUpdateInventory({
    required this.coreId,
    required this.homeId,
    required this.installed,
    required this.reviews,
    required this.preferences,
  });

  factory ServerComponentUpdateInventory.fromJson(Object? raw) {
    final json = _object(raw, {
      'schemaVersion',
      'coreId',
      'homeId',
      'installed',
      'reviews',
      'preferences',
    });
    if (json['schemaVersion'] != 1 ||
        json['installed'] is! List ||
        json['reviews'] is! List ||
        json['preferences'] is! List ||
        (json['installed'] as List).length > 6 ||
        (json['reviews'] as List).length > 6 ||
        (json['preferences'] as List).length > 6) {
      _invalid();
    }
    final installed = (json['installed'] as List)
        .map(ServerInstalledComponentUpdate.fromJson)
        .toList(growable: false);
    final reviews = (json['reviews'] as List)
        .map(ServerComponentUpdateReview.fromJson)
        .toList(growable: false);
    final preferences = (json['preferences'] as List)
        .map(ServerComponentReleasePreference.fromJson)
        .toList(growable: false);
    final coreId = _identity(json['coreId']);
    final homeId = _identity(json['homeId']);
    if (installed.length != reviews.length ||
        installed.length != preferences.length ||
        installed.asMap().entries.any(
          (entry) =>
              entry.value.installationId != reviews[entry.key].installationId ||
              entry.value.release.serviceId !=
                  preferences[entry.key].serviceId ||
              preferences[entry.key].coreId != coreId ||
              preferences[entry.key].homeId != homeId,
        ) ||
        installed.map((item) => item.installationId).toSet().length !=
            installed.length) {
      _invalid();
    }
    return ServerComponentUpdateInventory(
      coreId: coreId,
      homeId: homeId,
      installed: List.unmodifiable(installed),
      reviews: List.unmodifiable(reviews),
      preferences: List.unmodifiable(preferences),
    );
  }

  final String coreId;
  final String homeId;
  final List<ServerInstalledComponentUpdate> installed;
  final List<ServerComponentUpdateReview> reviews;
  final List<ServerComponentReleasePreference> preferences;
}
