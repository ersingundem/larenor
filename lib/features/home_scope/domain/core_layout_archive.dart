import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/home_data_scope.dart';
import '../../dashboard/domain/dashboard_layout_validation.dart';

/// Plain JSON model limit. This is not an encrypted file or file-loader limit.
const maxCoreLayoutArchiveBytes = 2 * 1024 * 1024;
const _maxRooms = 500;
const _maxRevision = 9223372036854775806;
const _invalid = CoreLayoutArchiveException('invalid_archive');
const _unsupported = CoreLayoutArchiveException('unsupported_layout');

final class CoreLayoutArchiveException implements Exception {
  const CoreLayoutArchiveException(this.code);
  final String code;
  @override
  String toString() => 'CoreLayoutArchiveException($code)';
}

final class CoreLayoutArchiveRoom {
  const CoreLayoutArchiveRoom._(this.id, this.name);
  final String id;
  final String name;

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  @override
  String toString() => 'CoreLayoutArchiveRoom';
}

/// A passive, local room arrangement owned by one Core/home/user tuple.
///
/// Parsing or matching this model grants no storage or session authority. It
/// does not describe Server resources, grants, devices or a restore operation.
final class CoreLayoutArchiveV1 {
  CoreLayoutArchiveV1._({
    required this.capturedAt,
    required this.scopeDigest,
    required this.sourceRevision,
    required List<CoreLayoutArchiveRoom> rooms,
  }) : rooms = List.unmodifiable(rooms);

  factory CoreLayoutArchiveV1.fromJson(Object? value) {
    final json = _closedObject(value, const {
      'kind',
      'version',
      'capturedAt',
      'scopeDigest',
      'sourceRevision',
      'rooms',
    });
    if (json['kind'] != 'core-room-layout' ||
        json['version'] is! int ||
        json['version'] != 1) {
      throw _invalid;
    }
    final digest = json['scopeDigest'];
    if (digest is! String ||
        digest.length != 64 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      throw _invalid;
    }
    final revision = json['sourceRevision'];
    if (revision is! int || revision < 0 || revision > _maxRevision) {
      throw _invalid;
    }
    final time = _canonicalTime(json['capturedAt']);
    final rawRooms = json['rooms'];
    if (rawRooms is! List || rawRooms.length > _maxRooms) throw _invalid;
    final ids = <String>{};
    final rooms = <CoreLayoutArchiveRoom>[];
    for (final raw in rawRooms) {
      final room = _closedObject(raw, const {'id', 'name'});
      final id = _roomText(room['id']);
      final name = _roomText(room['name']);
      if (!ids.add(id)) throw _invalid;
      rooms.add(CoreLayoutArchiveRoom._(id, name));
    }
    return CoreLayoutArchiveV1._(
      capturedAt: time,
      scopeDigest: digest,
      sourceRevision: revision,
      rooms: rooms,
    );
  }

  /// Bounds supplied UTF-8 JSON text before decoding. No file IO or crypto.
  factory CoreLayoutArchiveV1.decode(String value) {
    _checkBytes(value);
    try {
      return CoreLayoutArchiveV1.fromJson(jsonDecode(value));
    } on FormatException {
      throw _invalid;
    }
  }

  /// Explicit projection only when every other existing layout field is empty.
  /// Validate the raw source first: generated model decoding could discard
  /// unknown fields before this boundary has had a chance to reject them.
  factory CoreLayoutArchiveV1.fromScopedLayout({
    required HomeDataScope scope,
    required int sourceRevision,
    required DateTime capturedAt,
    required Object? layout,
  }) {
    if (!capturedAt.isUtc || capturedAt.microsecond != 0) throw _invalid;
    try {
      validateDashboardLayoutJson(layout);
    } on FormatException {
      throw _unsupported;
    } on JsonUnsupportedObjectError {
      throw _unsupported;
    }
    final source = layout as Map<String, dynamic>;
    for (final key in const ['tiles', 'favoriteEntityIds', 'hiddenEntityIds']) {
      if (source.containsKey(key)) {
        final value = source[key];
        if (value is! List || value.isNotEmpty) throw _unsupported;
      }
    }
    for (final key in const ['entityCardSizes', 'serviceCardSizes']) {
      if (source.containsKey(key)) {
        final value = source[key];
        if (value is! Map || value.isNotEmpty) throw _unsupported;
      }
    }
    final rawRooms = source.containsKey('rooms') ? source['rooms'] : const [];
    if (rawRooms is! List) throw _unsupported;
    final rooms = <Map<String, dynamic>>[];
    for (final raw in rawRooms) {
      final room = raw as Map<String, dynamic>;
      if (room['areaBinding'] != null) throw _unsupported;
      if (room.containsKey('entityIds')) {
        final ids = room['entityIds'];
        if (ids is! List || ids.isNotEmpty) throw _unsupported;
      }
      rooms.add({'id': room['id'], 'name': room['name']});
    }
    return CoreLayoutArchiveV1.fromJson({
      'kind': 'core-room-layout',
      'version': 1,
      'capturedAt': capturedAt.toIso8601String(),
      'scopeDigest': _digest(scope),
      'sourceRevision': sourceRevision,
      'rooms': rooms,
    });
  }

  final DateTime capturedAt;
  final String scopeDigest;

  /// Capture information, never a revision to install or an authorization hint.
  final int sourceRevision;

  /// The list itself is the order; IDs and names are preserved without trimming.
  final List<CoreLayoutArchiveRoom> rooms;

  bool matchesScope(HomeDataScope scope) => scopeDigest == _digest(scope);

  Map<String, dynamic> toJson() => {
    'kind': 'core-room-layout',
    'version': 1,
    'capturedAt': capturedAt.toIso8601String(),
    'scopeDigest': scopeDigest,
    'sourceRevision': sourceRevision,
    'rooms': [for (final room in rooms) room.toJson()],
  };

  String encode() {
    final value = jsonEncode(toJson());
    _checkBytes(value);
    return value;
  }

  @override
  String toString() => 'CoreLayoutArchiveV1';
}

Map<String, dynamic> _closedObject(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.toSet().containsAll(keys)) {
    throw _invalid;
  }
  return value;
}

String _roomText(Object? value) {
  // Match the existing layout's limit in Dart UTF-16 code units, not runes.
  if (value is! String ||
      value.isEmpty ||
      value.length > 256 ||
      value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    throw _invalid;
  }
  return value;
}

DateTime _canonicalTime(Object? value) {
  if (value is! String ||
      value.length != 24 ||
      !RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$')
          .hasMatch(value)) {
    throw _invalid;
  }
  final time = DateTime.tryParse(value);
  if (time == null || !time.isUtc || time.toIso8601String() != value) {
    throw _invalid;
  }
  return time;
}

String _digest(HomeDataScope scope) => sha256
    .convert(
      utf8.encode(
        jsonEncode([
          'larenor-core-layout-archive-scope-v1',
          scope.coreId,
          scope.homeId,
          scope.userId,
        ]),
      ),
    )
    .toString();

void _checkBytes(String value) {
  if (utf8.encode(value).length > maxCoreLayoutArchiveBytes) {
    throw const CoreLayoutArchiveException('archive_too_large');
  }
}
