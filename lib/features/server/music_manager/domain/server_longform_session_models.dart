import '../../domain/server_models.dart';
import 'server_music_manager_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    _invalid();
  }
  return value;
}

String _id(Object? value) {
  if (value is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

int _revision(Object? value) {
  if (value is! int || value < 1 || value > 0x7fffffffffffffff) _invalid();
  return value;
}

String _text(Object? value, int max) {
  if (value is! String ||
      value.isEmpty ||
      value.length > max ||
      value.trim() != value ||
      value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    _invalid();
  }
  return value;
}

double _position(Object? value) {
  if (value is! num || !value.isFinite || value < 0 || value > 8640000) {
    _invalid();
  }
  return value.toDouble();
}

DateTime? _timestamp(Object? value, {bool nullable = false}) {
  if (value == null && nullable) return null;
  if (value is! int || value < 0 || value > 253402300799) _invalid();
  return DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true);
}

bool _validLongformUri(String value) {
  if (value.length > 2048 || value.contains(RegExp(r'[\s?#@]'))) return false;
  final match = RegExp(r'^([a-z][a-z0-9_]{0,63})://[^\s]+$').firstMatch(value);
  return match != null &&
      !const {
        'content',
        'data',
        'file',
        'ftp',
        'http',
        'https',
        'javascript',
      }.contains(match.group(1));
}

enum ServerLongformPlaybackState { paused, playing, ended }

class ServerLongformBookmark {
  const ServerLongformBookmark({
    required this.id,
    required this.positionSeconds,
    required this.label,
  });

  factory ServerLongformBookmark.fromJson(Object? value) {
    final map = _object(value, {
      'schemaVersion',
      'bookmarkId',
      'positionSeconds',
      'label',
    });
    if (map['schemaVersion'] != 1) _invalid();
    return ServerLongformBookmark(
      id: _id(map['bookmarkId']),
      positionSeconds: _position(map['positionSeconds']),
      label: _text(map['label'], 80),
    );
  }

  final String id;
  final double positionSeconds;
  final String label;

  Map<String, Object> toJson() => {
    'schemaVersion': 1,
    'bookmarkId': id,
    'positionSeconds': positionSeconds,
    'label': label,
  };
}

class ServerLongformSession {
  const ServerLongformSession._({
    required this.id,
    required this.revision,
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.installationId,
    required this.installationRevision,
    required this.coreRevision,
    required this.managerRevision,
    required this.providerInstanceId,
    required this.mediaUri,
    required this.mediaType,
    required this.title,
    required this.durationSeconds,
    required this.positionSeconds,
    required this.playbackState,
    required this.sleepTimerEndsAt,
    required this.bookmarks,
    required this.ownedByCurrentSession,
    required this.updatedAt,
  });

  factory ServerLongformSession.fromJson(Object? value) {
    final map = _object(value, {
      'schemaVersion',
      'sessionId',
      'revision',
      'coreId',
      'homeId',
      'accountId',
      'installationId',
      'installationRevision',
      'coreRevision',
      'managerRevision',
      'providerInstanceId',
      'mediaUri',
      'mediaType',
      'title',
      'durationSeconds',
      'positionSeconds',
      'playbackState',
      'sleepTimerEndsAt',
      'bookmarks',
      'ownedByCurrentSession',
      'updatedAt',
    });
    final uri = map['mediaUri'];
    final rawBookmarks = map['bookmarks'];
    final rawState = map['playbackState'];
    if (map['schemaVersion'] != 1 ||
        uri is! String ||
        !_validLongformUri(uri) ||
        rawBookmarks is! List ||
        rawBookmarks.length > 64 ||
        map['ownedByCurrentSession'] is! bool ||
        rawState is! String) {
      _invalid();
    }
    final state = ServerLongformPlaybackState.values
        .where((item) => item.name == rawState)
        .firstOrNull;
    final duration = _position(map['durationSeconds']);
    final position = _position(map['positionSeconds']);
    final bookmarks = rawBookmarks
        .map(ServerLongformBookmark.fromJson)
        .toList(growable: false);
    if (state == null ||
        duration <= 0 ||
        position > duration ||
        (state == ServerLongformPlaybackState.ended && position != duration) ||
        bookmarks.any((item) => item.positionSeconds > duration) ||
        bookmarks.map((item) => item.id).toSet().length != bookmarks.length) {
      _invalid();
    }
    return ServerLongformSession._(
      id: _id(map['sessionId']),
      revision: _revision(map['revision']),
      coreId: _id(map['coreId']),
      homeId: _id(map['homeId']),
      accountId: _id(map['accountId']),
      installationId: _id(map['installationId']),
      installationRevision: _revision(map['installationRevision']),
      coreRevision: _revision(map['coreRevision']),
      managerRevision: _revision(map['managerRevision']),
      providerInstanceId: _text(map['providerInstanceId'], 128),
      mediaUri: uri,
      mediaType: _choice(map['mediaType'], {'audiobook', 'podcast_episode'}),
      title: _text(map['title'], 512),
      durationSeconds: duration,
      positionSeconds: position,
      playbackState: state,
      sleepTimerEndsAt: _timestamp(map['sleepTimerEndsAt'], nullable: true),
      bookmarks: List.unmodifiable(bookmarks),
      ownedByCurrentSession: map['ownedByCurrentSession'] as bool,
      updatedAt: _timestamp(map['updatedAt'])!,
    );
  }

  final String id, coreId, homeId, accountId, installationId;
  final String providerInstanceId, mediaUri, mediaType, title;
  final int revision, installationRevision, coreRevision, managerRevision;
  final double durationSeconds, positionSeconds;
  final ServerLongformPlaybackState playbackState;
  final DateTime? sleepTimerEndsAt;
  final List<ServerLongformBookmark> bookmarks;
  final bool ownedByCurrentSession;
  final DateTime updatedAt;

  double get progress => positionSeconds / durationSeconds;

  bool matches(ServerMusicManager manager, ServerMusicLongformItem item) =>
      installationId == manager.installationId &&
      installationRevision == manager.installationRevision &&
      coreRevision == manager.coreRevision &&
      managerRevision == manager.revision &&
      providerInstanceId == item.providerInstanceId &&
      mediaUri == item.uri &&
      mediaType == item.mediaType &&
      durationSeconds == item.durationSeconds;
}

String _choice(Object? value, Set<String> allowed) {
  if (value is! String || !allowed.contains(value)) _invalid();
  return value;
}
