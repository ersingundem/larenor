import '../../domain/server_models.dart';
import '../../media_catalog/domain/server_media_catalog_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');

final _identityPattern = RegExp(r'^[0-9a-f]{32}$');
final _mediaKeyPattern = RegExp(
  r'^(?:movie:tmdb:[1-9][0-9]{0,11}|episode:tvdb:[1-9][0-9]{0,11}:[0-9]{1,4}:[0-9]{1,5})$',
);
final _targetPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}$');
final _unsafeText = RegExp(
  r'[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069\ufeff]',
);

Map<String, dynamic> _object(Object? raw, Set<String> keys) {
  final value = serverObject(raw);
  if (value.length != keys.length || !value.keys.every(keys.contains)) {
    _invalid();
  }
  return value;
}

String _id(Object? value) {
  if (value is! String || !_identityPattern.hasMatch(value)) _invalid();
  return value;
}

int _revision(Object? value) {
  if (value is! int || value < 1 || value > 0x7ffffffffffffffe) _invalid();
  return value;
}

int _time(Object? value) {
  if (value is! int || value < 1 || value > 253402300799) _invalid();
  return value;
}

String _text(Object? value, int maximum) {
  if (value is! String ||
      value.isEmpty ||
      value.length > maximum ||
      value != value.trim() ||
      _unsafeText.hasMatch(value)) {
    _invalid();
  }
  return value;
}

enum ServerPersonalChannelState { active, cancelled }

enum ServerPersonalProgrammeState { scheduled, gap }

enum ServerPersonalProgrammeReason { available, deleted, unreachable }

enum ServerPersonalPlaybackMode { live, restart }

final class ServerPersonalChannelSource {
  const ServerPersonalChannelSource._({
    required this.installationId,
    required this.installationRevision,
    required this.snapshotRevision,
    required this.jellyfinServiceRevision,
    required this.itemId,
    required this.mediaKey,
    required this.title,
    required this.duration,
  });

  factory ServerPersonalChannelSource.fromCatalog(
    ServerMediaCatalogPage page,
    ServerMediaCatalogItem item, {
    required Duration duration,
  }) {
    if (!page.items.any((candidate) => identical(candidate, item)) ||
        duration.inSeconds < 60 ||
        duration.inSeconds > 86400) {
      throw const LarenorServerException('invalid_request');
    }
    return ServerPersonalChannelSource._(
      installationId: page.installationId,
      installationRevision: page.installationRevision,
      snapshotRevision: page.snapshotRevision,
      jellyfinServiceRevision: page.jellyfinServiceRevision,
      itemId: item.itemId,
      mediaKey: item.mediaKey,
      title: item.title,
      duration: duration,
    );
  }

  final String installationId, itemId, mediaKey, title;
  final int installationRevision, snapshotRevision, jellyfinServiceRevision;
  final Duration duration;

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'installationId': installationId,
    'expectedInstallationRevision': installationRevision,
    'expectedSnapshotRevision': snapshotRevision,
    'expectedJellyfinServiceRevision': jellyfinServiceRevision,
    'itemId': itemId,
    'mediaKey': mediaKey,
    'title': title,
    'durationSeconds': duration.inSeconds,
  };
}

final class ServerPersonalProgramme {
  const ServerPersonalProgramme._({
    required this.id,
    required this.revision,
    required this.position,
    required this.title,
    required this.itemId,
    required this.mediaKey,
    required this.startsAt,
    required this.endsAt,
    required this.state,
    required this.reason,
    required this.canRestart,
  });

  factory ServerPersonalProgramme.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'programmeId',
      'revision',
      'position',
      'title',
      'itemId',
      'mediaKey',
      'occurrenceStartsAt',
      'occurrenceEndsAt',
      'state',
      'reason',
      'canRestart',
    });
    final position = value['position'];
    final itemId = value['itemId'];
    final mediaKey = value['mediaKey'];
    final starts = _time(value['occurrenceStartsAt']);
    final ends = _time(value['occurrenceEndsAt']);
    final state = switch (value['state']) {
      'scheduled' => ServerPersonalProgrammeState.scheduled,
      'gap' => ServerPersonalProgrammeState.gap,
      _ => _invalid(),
    };
    final reason = switch (value['reason']) {
      'available' => ServerPersonalProgrammeReason.available,
      'deleted' => ServerPersonalProgrammeReason.deleted,
      'unreachable' => ServerPersonalProgrammeReason.unreachable,
      _ => _invalid(),
    };
    if (value['schemaVersion'] != 1 ||
        position is! int ||
        position < 0 ||
        position > 63 ||
        value['canRestart'] is! bool ||
        starts >= ends ||
        (state == ServerPersonalProgrammeState.scheduled) !=
            (reason == ServerPersonalProgrammeReason.available) ||
        (state == ServerPersonalProgrammeState.scheduled) != (itemId != null) ||
        (state == ServerPersonalProgrammeState.scheduled) !=
            (mediaKey != null) ||
        itemId != null &&
            (itemId is! String || !_identityPattern.hasMatch(itemId)) ||
        mediaKey != null &&
            (mediaKey is! String || !_mediaKeyPattern.hasMatch(mediaKey)) ||
        value['canRestart'] !=
            (state == ServerPersonalProgrammeState.scheduled)) {
      _invalid();
    }
    return ServerPersonalProgramme._(
      id: _id(value['programmeId']),
      revision: _revision(value['revision']),
      position: position,
      title: _text(value['title'], 240),
      itemId: itemId as String?,
      mediaKey: mediaKey as String?,
      startsAt: DateTime.fromMillisecondsSinceEpoch(starts * 1000, isUtc: true),
      endsAt: DateTime.fromMillisecondsSinceEpoch(ends * 1000, isUtc: true),
      state: state,
      reason: reason,
      canRestart: value['canRestart'] as bool,
    );
  }

  final String id, title;
  final String? itemId, mediaKey;
  final int revision, position;
  final DateTime startsAt, endsAt;
  final ServerPersonalProgrammeState state;
  final ServerPersonalProgrammeReason reason;
  final bool canRestart;

  bool contains(DateTime value) =>
      !value.isBefore(startsAt) && value.isBefore(endsAt);
}

final class ServerPersonalChannel {
  const ServerPersonalChannel._({
    required this.id,
    required this.accountRevision,
    required this.revision,
    required this.name,
    required this.state,
    required this.startsAt,
    required this.loop,
    required this.cycle,
    required this.guideFrom,
    required this.guideUntil,
    required this.programmes,
  });

  factory ServerPersonalChannel.fromJson(Object? raw, ServerSession session) {
    final context = session.context;
    final family = session.sessionFamilyId;
    if (context == null || family == null) _invalid();
    final value = _object(raw, {
      'schemaVersion',
      'channelId',
      'authority',
      'revision',
      'name',
      'state',
      'startsAt',
      'loop',
      'cycleSeconds',
      'guideFrom',
      'guideUntil',
      'programmes',
    });
    final authority = _object(value['authority'], {
      'schemaVersion',
      'coreId',
      'homeId',
      'accountId',
      'accountRevision',
      'sessionFamilyId',
    });
    if (value['schemaVersion'] != 1 ||
        authority['schemaVersion'] != 1 ||
        authority['coreId'] != context.coreId ||
        authority['homeId'] != context.homeId ||
        authority['accountId'] != session.user.id ||
        authority['sessionFamilyId'] != family ||
        value['loop'] is! bool ||
        value['programmes'] is! List) {
      _invalid();
    }
    final cycle = value['cycleSeconds'];
    if (cycle is! int || cycle < 60 || cycle > 604800) _invalid();
    final from = _time(value['guideFrom']);
    final until = _time(value['guideUntil']);
    if (from >= until || until - from > 604800) _invalid();
    final programmes = (value['programmes'] as List)
        .map(ServerPersonalProgramme.fromJson)
        .toList(growable: false);
    final programmeKeys = programmes
        .map((item) => '${item.id}:${item.startsAt.microsecondsSinceEpoch}')
        .toSet();
    if (programmes.length > 64 || programmeKeys.length != programmes.length) {
      _invalid();
    }
    for (var index = 1; index < programmes.length; index++) {
      if (programmes[index - 1].endsAt.isAfter(programmes[index].startsAt)) {
        _invalid();
      }
    }
    return ServerPersonalChannel._(
      id: _id(value['channelId']),
      accountRevision: _revision(authority['accountRevision']),
      revision: _revision(value['revision']),
      name: _text(value['name'], 80),
      state: switch (value['state']) {
        'active' => ServerPersonalChannelState.active,
        'cancelled' => ServerPersonalChannelState.cancelled,
        _ => _invalid(),
      },
      startsAt: DateTime.fromMillisecondsSinceEpoch(
        _time(value['startsAt']) * 1000,
        isUtc: true,
      ),
      loop: value['loop'] as bool,
      cycle: Duration(seconds: cycle),
      guideFrom: DateTime.fromMillisecondsSinceEpoch(from * 1000, isUtc: true),
      guideUntil: DateTime.fromMillisecondsSinceEpoch(
        until * 1000,
        isUtc: true,
      ),
      programmes: List.unmodifiable(programmes),
    );
  }

  final String id, name;
  final int accountRevision, revision;
  final ServerPersonalChannelState state;
  final DateTime startsAt, guideFrom, guideUntil;
  final bool loop;
  final Duration cycle;
  final List<ServerPersonalProgramme> programmes;

  ServerPersonalProgramme? liveAt(DateTime value) {
    for (final programme in programmes) {
      if (programme.contains(value)) return programme;
    }
    return null;
  }
}

final class ServerPersonalPlaybackSource {
  const ServerPersonalPlaybackSource._({
    required this.channelId,
    required this.channelRevision,
    required this.programmeId,
    required this.programmeRevision,
    required this.occurrenceStartsAt,
    required this.start,
    required this.installationId,
    required this.installationRevision,
    required this.snapshotRevision,
    required this.jellyfinServiceRevision,
    required this.itemId,
    required this.mediaKey,
  });

  factory ServerPersonalPlaybackSource.fromJson(
    Object? raw, {
    required ServerPersonalChannel channel,
    required ServerPersonalProgramme programme,
  }) {
    final value = _object(raw, {
      'schemaVersion',
      'channelId',
      'channelRevision',
      'programmeId',
      'programmeRevision',
      'occurrenceStartsAt',
      'startSeconds',
      'authority',
    });
    final authority = _object(value['authority'], {
      'installationId',
      'installationRevision',
      'snapshotRevision',
      'jellyfinServiceRevision',
      'itemId',
      'mediaKey',
    });
    final seconds = value['startSeconds'];
    if (value['schemaVersion'] != 1 ||
        value['channelId'] != channel.id ||
        value['channelRevision'] != channel.revision ||
        value['programmeId'] != programme.id ||
        value['programmeRevision'] != programme.revision ||
        value['occurrenceStartsAt'] !=
            programme.startsAt.millisecondsSinceEpoch ~/ 1000 ||
        authority['itemId'] != programme.itemId ||
        authority['mediaKey'] != programme.mediaKey ||
        seconds is! int ||
        seconds < 0 ||
        seconds > 86400) {
      _invalid();
    }
    return ServerPersonalPlaybackSource._(
      channelId: channel.id,
      channelRevision: channel.revision,
      programmeId: programme.id,
      programmeRevision: programme.revision,
      occurrenceStartsAt: programme.startsAt,
      start: Duration(seconds: seconds),
      installationId: _id(authority['installationId']),
      installationRevision: _revision(authority['installationRevision']),
      snapshotRevision: _revision(authority['snapshotRevision']),
      jellyfinServiceRevision: _revision(authority['jellyfinServiceRevision']),
      itemId: _id(authority['itemId']),
      mediaKey:
          authority['mediaKey'] is String &&
              _mediaKeyPattern.hasMatch(authority['mediaKey'] as String)
          ? authority['mediaKey'] as String
          : _invalid(),
    );
  }

  final String channelId, programmeId, installationId, itemId, mediaKey;
  final int channelRevision;
  final int programmeRevision;
  final int installationRevision, snapshotRevision, jellyfinServiceRevision;
  final DateTime occurrenceStartsAt;
  final Duration start;
}

enum ServerPersonalExecutionState {
  active,
  dispatching,
  needsAttention,
  cancelled,
}

enum ServerPersonalExecutionCode {
  scheduled,
  authenticatedReadback,
  effectUnknown,
  gap,
  sourceChanged,
  authorityChanged,
  sourceUnavailable,
  targetUnavailable,
  cancelled,
}

final class ServerPersonalChannelExecution {
  const ServerPersonalChannelExecution._({
    required this.channelId,
    required this.channelRevision,
    required this.revision,
    required this.targetId,
    required this.state,
    required this.code,
    required this.programmeId,
    required this.programmeRevision,
    required this.occurrenceStartsAt,
    required this.occurrenceEndsAt,
  });

  factory ServerPersonalChannelExecution.fromJson(
    Object? raw, {
    required String expectedChannelId,
    ServerPersonalPlaybackSource? expectedSource,
    String? expectedTargetId,
  }) {
    final value = _object(raw, {
      'schemaVersion',
      'channelId',
      'channelRevision',
      'revision',
      'targetId',
      'state',
      'code',
      'programmeId',
      'programmeRevision',
      'occurrenceStartsAt',
      'occurrenceEndsAt',
    });
    final targetId = value['targetId'];
    final programmeId = value['programmeId'];
    final programmeRevision = value['programmeRevision'];
    final startsAt = value['occurrenceStartsAt'];
    final endsAt = value['occurrenceEndsAt'];
    final hasOccurrence = programmeId != null;
    if (value['schemaVersion'] != 1 ||
        value['channelId'] != expectedChannelId ||
        targetId is! String ||
        !_targetPattern.hasMatch(targetId) ||
        (expectedTargetId != null && targetId != expectedTargetId) ||
        (hasOccurrence != (programmeRevision != null)) ||
        (hasOccurrence != (startsAt != null)) ||
        (hasOccurrence != (endsAt != null)) ||
        (hasOccurrence &&
            (_id(programmeId) != programmeId ||
                _revision(programmeRevision) != programmeRevision ||
                _time(startsAt) != startsAt ||
                _time(endsAt) != endsAt ||
                (startsAt as int) >= (endsAt as int)))) {
      _invalid();
    }
    final channelRevision = _revision(value['channelRevision']);
    if (expectedSource != null &&
        (channelRevision != expectedSource.channelRevision ||
            programmeId != expectedSource.programmeId ||
            programmeRevision != expectedSource.programmeRevision ||
            startsAt !=
                expectedSource.occurrenceStartsAt.millisecondsSinceEpoch ~/
                    1000)) {
      _invalid();
    }
    return ServerPersonalChannelExecution._(
      channelId: expectedChannelId,
      channelRevision: channelRevision,
      revision: _revision(value['revision']),
      targetId: targetId,
      state: switch (value['state']) {
        'active' => ServerPersonalExecutionState.active,
        'dispatching' => ServerPersonalExecutionState.dispatching,
        'needs_attention' => ServerPersonalExecutionState.needsAttention,
        'cancelled' => ServerPersonalExecutionState.cancelled,
        _ => _invalid(),
      },
      code: switch (value['code']) {
        'scheduled' => ServerPersonalExecutionCode.scheduled,
        'authenticated_readback' =>
          ServerPersonalExecutionCode.authenticatedReadback,
        'effect_unknown' => ServerPersonalExecutionCode.effectUnknown,
        'gap' => ServerPersonalExecutionCode.gap,
        'source_changed' => ServerPersonalExecutionCode.sourceChanged,
        'authority_changed' => ServerPersonalExecutionCode.authorityChanged,
        'source_unavailable' => ServerPersonalExecutionCode.sourceUnavailable,
        'target_unavailable' => ServerPersonalExecutionCode.targetUnavailable,
        'cancelled' => ServerPersonalExecutionCode.cancelled,
        _ => _invalid(),
      },
      programmeId: programmeId as String?,
      programmeRevision: programmeRevision as int?,
      occurrenceStartsAt: startsAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (startsAt as int) * 1000,
              isUtc: true,
            ),
      occurrenceEndsAt: endsAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (endsAt as int) * 1000,
              isUtc: true,
            ),
    );
  }

  final String channelId, targetId;
  final int channelRevision, revision;
  final ServerPersonalExecutionState state;
  final ServerPersonalExecutionCode code;
  final String? programmeId;
  final int? programmeRevision;
  final DateTime? occurrenceStartsAt, occurrenceEndsAt;
}
