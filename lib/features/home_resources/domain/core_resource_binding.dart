import 'package:flutter/foundation.dart';

import 'home_resource_models.dart';

/// Durable metadata reference used by room and dashboard layouts. It carries
/// no URL, token or command permission. Callers must resolve it against the
/// current authorized catalog before use.
@immutable
final class CoreResourceBinding {
  const CoreResourceBinding({
    this.schemaVersion = 1,
    required this.coreId,
    required this.homeId,
    required this.resourceId,
    required this.kind,
    required this.resourceRevision,
    required this.aclRevision,
    required this.userRevision,
  });

  factory CoreResourceBinding.fromRecord(
    HomeResourceRecord record, {
    required int userRevision,
  }) => CoreResourceBinding(
    coreId: record.context.coreId,
    homeId: record.context.homeId,
    resourceId: record.id,
    kind: record.kind,
    resourceRevision: record.revision,
    aclRevision: record.aclRevision,
    userRevision: userRevision,
  );

  factory CoreResourceBinding.fromJson(Object? raw) {
    const keys = {
      'schemaVersion',
      'coreId',
      'homeId',
      'resourceId',
      'kind',
      'resourceRevision',
      'aclRevision',
      'userRevision',
    };
    if (raw is! Map<String, dynamic> ||
        raw.keys.toSet().difference(keys).isNotEmpty ||
        !raw.keys.toSet().containsAll(keys) ||
        raw['schemaVersion'] != 1) {
      throw const FormatException('Invalid Core resource binding');
    }
    final identity = RegExp(r'^[0-9a-f]{32}$');
    String id(String key) {
      final value = raw[key];
      if (value is! String || !identity.hasMatch(value)) {
        throw const FormatException('Invalid Core resource binding');
      }
      return value;
    }

    int revision(String key) {
      final value = raw[key];
      if (value is! int || value < 1 || value > 0x7fffffffffffffff) {
        throw const FormatException('Invalid Core resource binding');
      }
      return value;
    }

    final kind = switch (raw['kind']) {
      'room' => HomeResourceKind.room,
      'resource' => HomeResourceKind.resource,
      _ => throw const FormatException('Invalid Core resource binding'),
    };
    return CoreResourceBinding(
      coreId: id('coreId'),
      homeId: id('homeId'),
      resourceId: id('resourceId'),
      kind: kind,
      resourceRevision: revision('resourceRevision'),
      aclRevision: revision('aclRevision'),
      userRevision: revision('userRevision'),
    );
  }

  final int schemaVersion;
  final String coreId, homeId, resourceId;
  final HomeResourceKind kind;
  final int resourceRevision, aclRevision, userRevision;

  Map<String, Object> toJson() => {
    'schemaVersion': schemaVersion,
    'coreId': coreId,
    'homeId': homeId,
    'resourceId': resourceId,
    'kind': kind.name,
    'resourceRevision': resourceRevision,
    'aclRevision': aclRevision,
    'userRevision': userRevision,
  };

  bool matches(HomeResourceRecord record, int? currentUserRevision) =>
      currentUserRevision == userRevision &&
      record.context.coreId == coreId &&
      record.context.homeId == homeId &&
      record.id == resourceId &&
      record.kind == kind &&
      record.revision == resourceRevision &&
      record.aclRevision == aclRevision;

  @override
  bool operator ==(Object other) =>
      other is CoreResourceBinding &&
      other.schemaVersion == schemaVersion &&
      other.coreId == coreId &&
      other.homeId == homeId &&
      other.resourceId == resourceId &&
      other.kind == kind &&
      other.resourceRevision == resourceRevision &&
      other.aclRevision == aclRevision &&
      other.userRevision == userRevision;

  @override
  int get hashCode => Object.hash(
    schemaVersion,
    coreId,
    homeId,
    resourceId,
    kind,
    resourceRevision,
    aclRevision,
    userRevision,
  );
}
