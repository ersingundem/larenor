final class CapabilityEvidenceRecord {
  const CapabilityEvidenceRecord({
    required this.id,
    required this.revision,
    required this.capabilityId,
    required this.oem,
    required this.model,
    required this.androidApi,
    required this.webViewPackage,
    required this.webViewVersion,
    required this.dexProfile,
    required this.permissions,
    required this.outcome,
    required this.artifactName,
    required this.artifactSha256,
    required this.sourceCommit,
    required this.testCase,
  });

  final String id, capabilityId, oem, model, webViewPackage, webViewVersion;
  final String dexProfile, artifactName, artifactSha256, sourceCommit, testCase;
  final int revision, androidApi;
  final List<String> permissions;
  final CapabilityEvidenceOutcome outcome;

  static final _id = RegExp(r'^[0-9a-f]{32}$');
  static final _digest = RegExp(r'^[0-9a-f]{64}$');
  static final _commit = RegExp(r'^[0-9a-f]{40}$');
  static final _artifact = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$');
  static final _case = RegExp(
    r'^[A-Za-z][A-Za-z0-9_-]*(?:\.[A-Za-z][A-Za-z0-9_-]*)+$',
  );
  static final _capability = RegExp(r'^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+$');
  static final _oem = RegExp(r'^[A-Za-z0-9][A-Za-z0-9 ._+()-]*$');
  static final _package = RegExp(r'^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+$');
  static final _version = RegExp(r'^[0-9A-Za-z][0-9A-Za-z._+-]*$');
  static final _permission = RegExp(
    r'^android\.permission\.[A-Z][A-Z0-9_]{1,79}$',
  );

  static Map<String, Object?> _map(Object? value, Set<String> keys) {
    if (value is! Map<String, Object?> ||
        value.keys.toSet().difference(keys).isNotEmpty ||
        keys.difference(value.keys.toSet()).isNotEmpty) {
      throw const FormatException('Invalid evidence');
    }
    return value;
  }

  static String _text(Object? value, RegExp pattern, int max) {
    if (value is! String || value.length > max || !pattern.hasMatch(value)) {
      throw const FormatException('Invalid evidence');
    }
    return value;
  }

  factory CapabilityEvidenceRecord.fromJson(Object? json) {
    final map = _map(json, {
      'schemaVersion',
      'id',
      'revision',
      'capabilityId',
      'target',
      'outcome',
      'artifactName',
      'artifactSha256',
      'sourceCommit',
      'testCase',
      'updatedAt',
    });
    if (map['schemaVersion'] != 1 ||
        map['schemaVersion'] is! int ||
        map['revision'] is! int ||
        (map['revision'] as int) < 1 ||
        map['updatedAt'] is! num ||
        !(map['updatedAt'] as num).isFinite) {
      throw const FormatException('Invalid evidence');
    }
    final target = _map(map['target'], {
      'oem',
      'model',
      'androidApi',
      'webViewPackage',
      'webViewVersion',
      'dexProfile',
      'permissions',
    });
    final permissions = target['permissions'];
    if (target['androidApi'] is! int ||
        (target['androidApi'] as int) < 26 ||
        (target['androidApi'] as int) > 100 ||
        permissions is! List ||
        permissions.length > 32 ||
        permissions.any(
          (item) => item is! String || !_permission.hasMatch(item),
        ) ||
        permissions.cast<String>().toSet().length != permissions.length ||
        permissions.cast<String>().join('\n') !=
            (permissions.cast<String>().toList()..sort()).join('\n')) {
      throw const FormatException('Invalid evidence');
    }
    final profile = _text(
      target['dexProfile'],
      RegExp(r'^(none|window|external_display|managed_kiosk)$'),
      32,
    );
    final status = map['outcome'];
    if (status is! String) throw const FormatException('Invalid evidence');
    final outcome = CapabilityEvidenceOutcome.values
        .where((item) => item.wireName == status)
        .firstOrNull;
    if (outcome == null) throw const FormatException('Invalid evidence');
    return CapabilityEvidenceRecord(
      id: _text(map['id'], _id, 32),
      revision: map['revision'] as int,
      capabilityId: _text(map['capabilityId'], _capability, 80),
      oem: _text(target['oem'], _oem, 48),
      model: _text(target['model'], _oem, 80),
      androidApi: target['androidApi'] as int,
      webViewPackage: _text(target['webViewPackage'], _package, 120),
      webViewVersion: _text(target['webViewVersion'], _version, 64),
      dexProfile: profile,
      permissions: List.unmodifiable(permissions.cast<String>()),
      outcome: outcome,
      artifactName: _text(map['artifactName'], _artifact, 100),
      artifactSha256: _text(map['artifactSha256'], _digest, 64),
      sourceCommit: _text(map['sourceCommit'], _commit, 40),
      testCase: _text(map['testCase'], _case, 100),
    );
  }
}

enum CapabilityEvidenceOutcome {
  tested('tested'),
  failed('failed'),
  untested('untested'),
  manualRequired('manual_required');

  const CapabilityEvidenceOutcome(this.wireName);
  final String wireName;
}
