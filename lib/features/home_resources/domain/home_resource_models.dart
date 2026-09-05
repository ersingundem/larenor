import '../../server/domain/server_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');
Map<Object?, Object?> _object(Object? value, Set<String> keys) {
  if (value is! Map ||
      value.length != keys.length ||
      !keys.every(value.containsKey))
    _invalid();
  return value;
}

String _hex(Object? value, int length) {
  if (value is! String ||
      value.length != length ||
      !RegExp(r'^[0-9a-f]+$').hasMatch(value))
    _invalid();
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

enum HomeResourceKind { room, resource }

/// Public metadata only; write permission does not expose a device command.
final class HomeResourceRecord {
  const HomeResourceRecord._({
    required this.context,
    required this.id,
    required this.kind,
    required this.label,
    required this.order,
    required this.revision,
    required this.aclRevision,
    required this.canWrite,
  });
  factory HomeResourceRecord.fromJson(
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
    final kind = switch (ref['kind']) {
      'room' => HomeResourceKind.room,
      'resource' => HomeResourceKind.resource,
      _ => _invalid(),
    };
    final label = value['label'];
    if (label is! String ||
        label.runes.isEmpty ||
        label.runes.length > 80 ||
        label.runes.any(
          (rune) =>
              rune < 32 || rune == 127 || rune >= 0xd800 && rune <= 0xdfff,
        ))
      _invalid();
    final trimmed = label.replaceAll(_edgeWhitespace, '');
    if (trimmed.isEmpty) _invalid();
    final permissions = _object(value['permissions'], {'read', 'write'});
    if (permissions['read'] != true || permissions['write'] is! bool)
      _invalid();
    return HomeResourceRecord._(
      context: context,
      id: _hex(ref['id'], 32),
      kind: kind,
      label: trimmed,
      order: _integer(value['order'], 0, 10000),
      revision: _integer(value['revision'], 1, 9223372036854775807),
      aclRevision: _integer(value['aclRevision'], 1, 9223372036854775807),
      canWrite: permissions['write'] as bool,
    );
  }
  final ServerContext context;
  final String id, label;
  final HomeResourceKind kind;
  final int order, revision, aclRevision;
  final bool canWrite;
  @override
  String toString() => 'HomeResourceRecord';
}

final class HomeResourcePage {
  const HomeResourcePage._(
    this.context,
    this.entries,
    this.snapshot,
    this.nextAfter,
  );
  static const pageSize = 25;
  static const maximumRecords = 512;
  factory HomeResourcePage.fromJson(
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
    if (expectedSnapshot != null && snapshot != _hex(expectedSnapshot, 64))
      _invalid();
    if (after != null) {
      _hex(after, 32);
      if (expectedSnapshot == null) _invalid();
    }
    final rawEntries = value['entries'];
    if (rawEntries is! List || rawEntries.length > limit) _invalid();
    final entries = <HomeResourceRecord>[];
    var previous = after ?? '';
    for (final raw in rawEntries) {
      final entry = HomeResourceRecord.fromJson(raw, expectedContext: context);
      if (entry.id.compareTo(previous) <= 0) _invalid();
      entries.add(entry);
      previous = entry.id;
    }
    final next = value['nextAfter'] == null
        ? null
        : _hex(value['nextAfter'], 32);
    if (next != null && (entries.isEmpty || next != entries.last.id))
      _invalid();
    return HomeResourcePage._(
      context,
      List.unmodifiable(entries),
      snapshot,
      next,
    );
  }
  final ServerContext context;
  final List<HomeResourceRecord> entries;
  final String snapshot;
  final String? nextAfter;
  @override
  String toString() => 'HomeResourcePage';
}
