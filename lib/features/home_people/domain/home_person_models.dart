import '../../server/domain/server_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');
Map<Object?, Object?> _object(Object? value, Set<String> keys) {
  if (value is! Map ||
      value.length != keys.length ||
      !keys.every(value.containsKey)) {
    _invalid();
  }
  return value;
}

String _hex(Object? value, int length) {
  if (value is! String ||
      value.length != length ||
      !RegExp(r'^[0-9a-f]+$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

int _integer(Object? value, int minimum, int maximum) {
  if (value is! int || value < minimum || value > maximum) _invalid();
  return value;
}

// Match Python str.strip used by the Server. Dart's trim additionally removes
// BOM, which the actual wire contract allows as ordinary label content.
final _edgeWhitespace = RegExp(
  r'^[\x09-\x0d\x1c-\x20\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+|[\x09-\x0d\x1c-\x20\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+$',
);


/// Household profile metadata. It is neither an account nor an upstream person.
/// Permissions are observations, not current authorization or device commands.
final class HomePersonRecord {
  const HomePersonRecord._({
    required this.context,
    required this.id,
    required this.label,
    required this.order,
    required this.revision,
    required this.aclRevision,
    required this.canWrite,
  });
  factory HomePersonRecord.fromJson(
    Object? raw, {
    required ServerContext expectedContext,
  }) {
    final value = _object(raw, {
      'ref',
      'label',
      'order',
      'revision',
      'aclRevision',
      'permissions',
    });
    final ref = _object(value['ref'], {
      'schemaVersion',
      'coreId',
      'homeId',
      'kind',
      'id',
    });
    final context = ServerContext.fromJson({
      for (final key in ['schemaVersion', 'coreId', 'homeId']) key: ref[key],
    });
    if (context != expectedContext) _invalid();
    if (ref['kind'] != 'person') _invalid();
    final label = value['label'];
    if (label is! String ||
        label.runes.isEmpty ||
        label.runes.length > 80 ||
        label.runes.any(
          (rune) =>
              rune < 32 || rune == 127 || rune >= 0xd800 && rune <= 0xdfff,
        )) {
      _invalid();
    }
    final trimmed = label.replaceAll(_edgeWhitespace, '');
    if (trimmed.isEmpty) _invalid();
    final permissions = _object(value['permissions'], {'read', 'write'});
    if (permissions['read'] != true || permissions['write'] is! bool) {
      _invalid();
    }
    return HomePersonRecord._(
      context: context,
      id: _hex(ref['id'], 32),
      label: trimmed,
      order: _integer(value['order'], 0, 10000),
      revision: _integer(value['revision'], 1, 9223372036854775807),
      aclRevision: _integer(value['aclRevision'], 1, 9223372036854775807),
      canWrite: permissions['write'] as bool,
    );
  }
  final ServerContext context;
  final String id, label;
  final int order, revision, aclRevision;
  final bool canWrite;
  @override
  String toString() => 'HomePersonRecord';
}

final class HomePeoplePage {
  const HomePeoplePage._(
    this.context,
    this.entries,
    this.snapshot,
    this.nextAfter,
  );
  static const pageSize = 25;
  static const maximumRecords = 128;
  factory HomePeoplePage.fromJson(
    Object? raw, {
    required ServerContext expectedContext,
    String? after,
    String? expectedSnapshot,
    int limit = pageSize,
  }) {
    if (limit < 1 || limit > 100) _invalid();
    final value = _object(raw, {'scope', 'entries', 'snapshot', 'nextAfter'});
    final context = ServerContext.fromJson(value['scope']);
    if (context != expectedContext) _invalid();
    final snapshot = _hex(value['snapshot'], 64);
    if (expectedSnapshot != null && snapshot != _hex(expectedSnapshot, 64)) {
      _invalid();
    }
    if (after != null) {
      _hex(after, 32);
      if (expectedSnapshot == null) _invalid();
    }
    final rawEntries = value['entries'];
    if (rawEntries is! List || rawEntries.length > limit) _invalid();
    final entries = <HomePersonRecord>[];
    var previous = after ?? '';
    for (final raw in rawEntries) {
      final entry = HomePersonRecord.fromJson(raw, expectedContext: context);
      if (entry.id.compareTo(previous) <= 0) _invalid();
      entries.add(entry);
      previous = entry.id;
    }
    final next = value['nextAfter'] == null
        ? null
        : _hex(value['nextAfter'], 32);
    if (next != null && (entries.isEmpty || next != entries.last.id)) {
      _invalid();
    }
    return HomePeoplePage._(
      context,
      List.unmodifiable(entries),
      snapshot,
      next,
    );
  }
  final ServerContext context;
  final List<HomePersonRecord> entries;
  final String snapshot;
  final String? nextAfter;
  @override
  String toString() => 'HomePeoplePage';
}

/// Immutable request metadata; this value carries no authorization.
final class HomePersonMetadata {
  factory HomePersonMetadata({required String label, required int order}) {
    final runes = label.runes;
    if (runes.isEmpty ||
        runes.length > 80 ||
        order < 0 ||
        order > 10000 ||
        runes.any(
          (rune) =>
              rune < 32 || rune == 127 || rune >= 0xd800 && rune <= 0xdfff,
        )) {
      throw const LarenorServerException('invalid_request');
    }
    // Same Python str.strip edges as the existing read model. BOM is content.
    final canonical = label.replaceAll(_edgeWhitespace, '');
    if (canonical.isEmpty) {
      throw const LarenorServerException('invalid_request');
    }
    return HomePersonMetadata._(canonical, order);
  }
  const HomePersonMetadata._(this.label, this.order);
  final String label;
  final int order;
  Map<String, dynamic> toJson() => {'label': label, 'order': order};
  @override
  String toString() => 'HomePersonMetadata';
}


String _subject(Object? value) {
  if (value is! String || !HomePersonGrants.isSubjectId(value)) _invalid();
  return value;
}

int _revision(Object? value) {
  if (value is! int ||
      value < 1 ||
      value > HomePersonGrants.maximumRevision) {
    _invalid();
  }
  return value;
}

({String subject, HomePersonPermission permission}) _grant(
  Object? raw,
  HomePersonRecord target,
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
      ref['kind'] != 'person' ||
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
        ? HomePersonPermission.readWrite
        : permissions['read'] == true
        ? HomePersonPermission.readOnly
        : HomePersonPermission.none,
  );
}

enum HomePersonPermission {
  none,
  readOnly,
  readWrite;

  Map<String, bool> toJson() => {
    'read': this != none,
    'write': this == readWrite,
  };
}

/// A versioned snapshot, not an authorization grant for the current actor.
final class HomePersonGrants {
  HomePersonGrants._(this.target, this.aclRevision, this.grants);
  factory HomePersonGrants.fromJson(
    Object? raw, {
    required HomePersonRecord target,
  }) {
    final value = _object(raw, {'aclRevision', 'grants'});
    final revision = _revision(value['aclRevision']);
    final entries = value['grants'];
    if (revision < target.aclRevision ||
        entries is! List ||
        entries.length > maximumGrants) {
      _invalid();
    }
    final grants = <String, HomePersonPermission>{};
    var previous = '';
    for (final raw in entries) {
      final entry = _grant(raw, target, revision);
      if (entry.subject.compareTo(previous) <= 0 ||
          entry.permission == HomePersonPermission.none) {
        _invalid();
      }
      grants[entry.subject] = entry.permission;
      previous = entry.subject;
    }
    return HomePersonGrants._(target, revision, Map.unmodifiable(grants));
  }

  static const maximumRevision = 9223372036854775807;
  static const maximumGrants = 128;
  static bool isSubjectId(String value) =>
      value.length == 32 && RegExp(r'^[0-9a-f]{32}$').hasMatch(value);

  final HomePersonRecord target;
  final int aclRevision;
  final Map<String, HomePersonPermission> grants;
  HomePersonPermission permissionFor(String subjectId) =>
      grants[subjectId] ?? HomePersonPermission.none;
  HomePersonGrants withUpdatedGrant(
    Object? raw, {
    required String subjectId,
    required HomePersonPermission permission,
  }) {
    final changed = permissionFor(subjectId) != permission;
    if (changed && aclRevision == maximumRevision) _invalid();
    final nextRevision = changed ? aclRevision + 1 : aclRevision;
    final value = _object(raw, {'grant'});
    final grant = _grant(value['grant'], target, nextRevision);
    if (grant.subject != subjectId || grant.permission != permission) {
      _invalid();
    }
    final updated = Map<String, HomePersonPermission>.of(grants);
    if (permission == HomePersonPermission.none) {
      updated.remove(subjectId);
    } else {
      updated[subjectId] = permission;
    }
    if (updated.length > maximumGrants) _invalid();
    final subjects = updated.keys.toList()..sort();
    return HomePersonGrants._(
      target,
      nextRevision,
      Map.unmodifiable({
        for (final subject in subjects) subject: updated[subject]!,
      }),
    );
  }

  @override
  String toString() => 'HomePersonGrants';
}
