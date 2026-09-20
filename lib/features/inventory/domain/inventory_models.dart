import '../../server/domain/server_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');
Map<Object?, Object?> _object(Object? raw, Set<String> keys) {
  if (raw is! Map ||
      raw.length != keys.length ||
      !keys.every(raw.containsKey)) {
    _invalid();
  }
  return raw;
}

String _hex(Object? value, [int length = 32]) {
  if (value is! String ||
      value.length != length ||
      !RegExp('^[0-9a-f]{$length}\$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

int _revision(Object? value) {
  if (value is! int || value < 1 || value > 9223372036854775807) _invalid();
  return value;
}

String? _optionalHex(Object? value) => value == null ? null : _hex(value);

final class InventoryQr {
  const InventoryQr._(this.context, this.itemId, this.canonical);
  factory InventoryQr.parse(String raw) {
    final match = RegExp(
      r'^larenor:inventory:v1:([0-9a-f]{32}):([0-9a-f]{32}):([0-9a-f]{32})$',
    ).firstMatch(raw);
    if (match == null) throw const FormatException('Invalid inventory QR.');
    final context = ServerContext.fromJson({
      'schemaVersion': 1,
      'coreId': match.group(1),
      'homeId': match.group(2),
    });
    return InventoryQr._(context, match.group(3)!, raw);
  }
  final ServerContext context;
  final String itemId, canonical;
  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'format': 'larenor_inventory_v1',
    'value': canonical,
  };
  @override
  String toString() => 'InventoryQr';
}

final class InventoryLinks {
  const InventoryLinks._(this.roomId, this.deviceId, this.documentIds);
  factory InventoryLinks.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'roomId',
      'deviceId',
      'documentIds',
    });
    if (value['schemaVersion'] != 1) _invalid();
    final documents = value['documentIds'];
    if (documents is! List || documents.length > 16) _invalid();
    final parsed = documents.map(_hex).toList(growable: false);
    if (parsed.toSet().length != parsed.length) _invalid();
    return InventoryLinks._(
      _optionalHex(value['roomId']),
      _optionalHex(value['deviceId']),
      List.unmodifiable(parsed),
    );
  }
  final String? roomId, deviceId;
  final List<String> documentIds;
}

final class InventoryItem {
  const InventoryItem._(
    this.context,
    this.id,
    this.revision,
    this.label,
    this.links,
  );
  factory InventoryItem.fromResponse(
    Object? raw, {
    required ServerContext expected,
  }) {
    final response = _object(raw, {'item'});
    final value = _object(response['item'], {
      'schemaVersion',
      'ref',
      'revision',
      'label',
      'links',
    });
    if (value['schemaVersion'] != 1) _invalid();
    final ref = _object(value['ref'], {
      'schemaVersion',
      'coreId',
      'homeId',
      'kind',
      'id',
    });
    if (ref['kind'] != 'inventory_item') _invalid();
    final context = ServerContext.fromJson({
      'schemaVersion': ref['schemaVersion'],
      'coreId': ref['coreId'],
      'homeId': ref['homeId'],
    });
    if (context != expected) _invalid();
    final label = value['label'];
    if (label is! String ||
        label.isEmpty ||
        label.runes.length > 120 ||
        label.runes.any(
          (r) => r < 32 || r == 127 || r >= 0xd800 && r <= 0xdfff,
        )) {
      _invalid();
    }
    return InventoryItem._(
      context,
      _hex(ref['id']),
      _revision(value['revision']),
      label,
      InventoryLinks.fromJson(value['links']),
    );
  }
  final ServerContext context;
  final String id, label;
  final int revision;
  final InventoryLinks links;
  @override
  String toString() => 'InventoryItem';
}

final class InventoryGrants {
  const InventoryGrants._(this.itemRevision, this.subjectIds);
  factory InventoryGrants.fromResponse(
    Object? raw, {
    required InventoryItem expectedItem,
  }) {
    final value = _object(raw, {'schemaVersion', 'itemRevision', 'grants'});
    if (value['schemaVersion'] != 1 ||
        _revision(value['itemRevision']) != expectedItem.revision) {
      _invalid();
    }
    final source = value['grants'];
    if (source is! List || source.length > 64) _invalid();
    final ids = <String>[];
    for (final rawGrant in source) {
      final grant = _object(rawGrant, {'schemaVersion', 'subjectId'});
      if (grant['schemaVersion'] != 1) _invalid();
      ids.add(_hex(grant['subjectId']));
    }
    final sorted = [...ids]..sort();
    if (ids.toSet().length != ids.length || sorted.join() != ids.join()) {
      _invalid();
    }
    return InventoryGrants._(expectedItem.revision, List.unmodifiable(ids));
  }
  final int itemRevision;
  final List<String> subjectIds;
}

enum InventoryAuditAction { create, update, grant, revoke }

final class InventoryAuditEntry {
  const InventoryAuditEntry._(
    this.sequence,
    this.action,
    this.actorId,
    this.itemRevision,
    this.createdAt,
  );
  factory InventoryAuditEntry.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'sequence',
      'action',
      'actorId',
      'itemRevision',
      'createdAt',
    });
    if (value['schemaVersion'] != 1) _invalid();
    final sequence = _revision(value['sequence']);
    final action = switch (value['action']) {
      'create' => InventoryAuditAction.create,
      'update' => InventoryAuditAction.update,
      'grant' => InventoryAuditAction.grant,
      'revoke' => InventoryAuditAction.revoke,
      _ => _invalid(),
    };
    final timestamp = value['createdAt'];
    if (timestamp is! num || !timestamp.isFinite || timestamp < 0) _invalid();
    return InventoryAuditEntry._(
      sequence,
      action,
      _hex(value['actorId']),
      _revision(value['itemRevision']),
      timestamp.toDouble(),
    );
  }
  final int sequence, itemRevision;
  final InventoryAuditAction action;
  final String actorId;
  final double createdAt;
}

final class InventoryHistory {
  const InventoryHistory._(this.verified, this.entries);
  factory InventoryHistory.fromResponse(
    Object? raw, {
    required InventoryItem expectedItem,
  }) {
    final value = _object(raw, {'schemaVersion', 'verified', 'entries'});
    if (value['schemaVersion'] != 1 || value['verified'] != true) _invalid();
    final source = value['entries'];
    if (source is! List || source.isEmpty || source.length > 100) _invalid();
    final entries = source
        .map(InventoryAuditEntry.fromJson)
        .toList(growable: false);
    for (var index = 1; index < entries.length; index++) {
      if (entries[index].sequence <= entries[index - 1].sequence ||
          entries[index].itemRevision < entries[index - 1].itemRevision) {
        _invalid();
      }
    }
    if (entries.last.itemRevision != expectedItem.revision) _invalid();
    return InventoryHistory._(true, List.unmodifiable(entries));
  }
  final bool verified;
  final List<InventoryAuditEntry> entries;
}

final class InventoryDetail {
  const InventoryDetail({
    required this.item,
    required this.history,
    this.grants,
  });
  final InventoryItem item;
  final InventoryHistory history;
  final InventoryGrants? grants;
}
