import '../../server/domain/server_models.dart';
import 'home_resource_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');

Map<Object?, Object?> _object(Object? value, Set<String> keys) {
  if (value is! Map ||
      value.length != keys.length ||
      !keys.every(value.containsKey)) {
    _invalid();
  }
  return value;
}

String _subject(Object? value) {
  if (value is! String || !HomeResourceGrants.isSubjectId(value)) _invalid();
  return value;
}

int _revision(Object? value) {
  if (value is! int ||
      value < 1 ||
      value > HomeResourceGrants.maximumRevision) {
    _invalid();
  }
  return value;
}

({String subject, HomeResourcePermission permission}) _grant(
  Object? raw,
  HomeResourceRecord target,
  int revision,
) {
  final value = _object(raw, {
    'subjectId',
    'target',
    'aclRevision',
    'permissions',
  });
  final ref = _object(value['target'], {
    'schemaVersion',
    'coreId',
    'homeId',
    'kind',
    'id',
  });
  if (ref['schemaVersion'] is! int ||
      ref['schemaVersion'] != 1 ||
      ref['coreId'] != target.context.coreId ||
      ref['homeId'] != target.context.homeId ||
      ref['id'] != target.id ||
      ref['kind'] != target.kind.name ||
      _revision(value['aclRevision']) != revision) {
    _invalid();
  }
  final permissions = _object(value['permissions'], {'read', 'write'});
  if (permissions['read'] is! bool ||
      permissions['write'] is! bool ||
      permissions['write'] == true && permissions['read'] != true) {
    _invalid();
  }
  return (
    subject: _subject(value['subjectId']),
    permission: permissions['write'] == true
        ? HomeResourcePermission.readWrite
        : permissions['read'] == true
        ? HomeResourcePermission.readOnly
        : HomeResourcePermission.none,
  );
}

enum HomeResourcePermission {
  none,
  readOnly,
  readWrite;

  Map<String, bool> toJson() => {
    'read': this != none,
    'write': this == readWrite,
  };
}

/// A versioned snapshot, not an authorization grant for the current actor.
final class HomeResourceGrants {
  HomeResourceGrants._(this.target, this.aclRevision, this.grants);
  factory HomeResourceGrants.fromJson(
    Object? raw, {
    required HomeResourceRecord target,
  }) {
    final value = _object(raw, {'aclRevision', 'grants'});
    final revision = _revision(value['aclRevision']);
    final entries = value['grants'];
    if (revision < target.aclRevision ||
        entries is! List ||
        entries.length > maximumGrants) {
      _invalid();
    }
    final grants = <String, HomeResourcePermission>{};
    var previous = '';
    for (final raw in entries) {
      final entry = _grant(raw, target, revision);
      if (entry.subject.compareTo(previous) <= 0 ||
          entry.permission == HomeResourcePermission.none) {
        _invalid();
      }
      grants[entry.subject] = entry.permission;
      previous = entry.subject;
    }
    return HomeResourceGrants._(target, revision, Map.unmodifiable(grants));
  }

  static const maximumRevision = 9223372036854775807;
  static const maximumGrants = 128;
  static bool isSubjectId(String value) =>
      value.length == 32 && RegExp(r'^[0-9a-f]{32}$').hasMatch(value);

  final HomeResourceRecord target;
  final int aclRevision;
  final Map<String, HomeResourcePermission> grants;
  HomeResourcePermission permissionFor(String subjectId) =>
      grants[subjectId] ?? HomeResourcePermission.none;
  HomeResourceGrants withUpdatedGrant(
    Object? raw, {
    required String subjectId,
    required HomeResourcePermission permission,
  }) {
    final changed = permissionFor(subjectId) != permission;
    if (changed && aclRevision == maximumRevision) _invalid();
    final nextRevision = changed ? aclRevision + 1 : aclRevision;
    final value = _object(raw, {'grant'});
    final grant = _grant(value['grant'], target, nextRevision);
    if (grant.subject != subjectId || grant.permission != permission) {
      _invalid();
    }
    final updated = Map<String, HomeResourcePermission>.of(grants);
    if (permission == HomeResourcePermission.none) {
      updated.remove(subjectId);
    } else {
      updated[subjectId] = permission;
    }
    if (updated.length > maximumGrants) _invalid();
    final subjects = updated.keys.toList()..sort();
    return HomeResourceGrants._(
      target,
      nextRevision,
      Map.unmodifiable({
        for (final subject in subjects) subject: updated[subject]!,
      }),
    );
  }

  @override
  String toString() => 'HomeResourceGrants';
}
