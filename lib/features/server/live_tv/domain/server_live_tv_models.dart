import 'package:timezone/data/latest.dart' as database;
import 'package:timezone/timezone.dart' as tz;

import '../../domain/server_models.dart';

enum ServerLiveTvRecordingState {
  scheduled,
  recording,
  interrupted,
  completed,
  cancelled,
  partial,
  uncertain,
}

final class ServerLiveTvSourceOption {
  const ServerLiveTvSourceOption({
    required this.serviceId,
    required this.serviceRevision,
    required this.name,
    required this.version,
  });

  factory ServerLiveTvSourceOption.fromJson(Object? raw) {
    final value = _object(raw, {
      'serviceId',
      'serviceRevision',
      'name',
      'version',
    });
    final revision = value['serviceRevision'];
    if (revision is! int || revision < 1 || revision > 0x1fffffffffffff) {
      _invalid();
    }
    final version = _text(value['version'], 80);
    if (!RegExp(r'^10\.11\.[0-9]{1,6}$').hasMatch(version)) _invalid();
    return ServerLiveTvSourceOption(
      serviceId: _id(value['serviceId']),
      serviceRevision: revision,
      name: _text(value['name'], 80),
      version: version,
    );
  }

  final String serviceId, name, version;
  final int serviceRevision;
}

final class ServerLiveTvSourceOptions {
  const ServerLiveTvSourceOptions(this.expectedRevision, this.services);
  final int expectedRevision;
  final List<ServerLiveTvSourceOption> services;
}

final class ServerLiveTvProgramme {
  const ServerLiveTvProgramme({
    required this.id,
    required this.channelId,
    required this.channelName,
    required this.title,
    required this.startsAt,
    required this.endsAt,
  });

  factory ServerLiveTvProgramme.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'programmeId',
      'channelId',
      'channelName',
      'title',
      'startsAt',
      'endsAt',
    });
    if (value['schemaVersion'] != 1) _invalid();
    final start = _instant(value['startsAt']);
    final end = _instant(value['endsAt']);
    if (!start.isBefore(end) ||
        end.difference(start) > const Duration(days: 1)) {
      _invalid();
    }
    return ServerLiveTvProgramme(
      id: _id(value['programmeId']),
      channelId: _id(value['channelId']),
      channelName: _text(value['channelName'], 120),
      title: _text(value['title'], 240),
      startsAt: start,
      endsAt: end,
    );
  }

  final String id, channelId, channelName, title;
  final DateTime startsAt, endsAt;
}

final class ServerLiveTvRecording {
  const ServerLiveTvRecording({
    required this.id,
    required this.revision,
    required this.providerRevision,
    required this.readbackRevision,
    required this.programmeId,
    required this.channelId,
    required this.channelName,
    required this.title,
    required this.startsAt,
    required this.endsAt,
    required this.state,
    required this.bytesWritten,
    required this.restartCount,
  });

  factory ServerLiveTvRecording.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'recordingId',
      'revision',
      'providerRevision',
      'readbackRevision',
      'programmeId',
      'channelId',
      'channelName',
      'title',
      'startsAt',
      'endsAt',
      'state',
      'bytesWritten',
      'restartCount',
    });
    final state = ServerLiveTvRecordingState.values
        .cast<ServerLiveTvRecordingState?>()
        .firstWhere((item) => item?.name == value['state'], orElse: () => null);
    final revision = value['revision'];
    final providerRevision = value['providerRevision'];
    final readbackRevision = value['readbackRevision'];
    final bytes = value['bytesWritten'];
    final restarts = value['restartCount'];
    final start = _instant(value['startsAt']);
    final end = _instant(value['endsAt']);
    if (value['schemaVersion'] != 1 ||
        state == null ||
        revision is! int ||
        revision < 1 ||
        providerRevision is! int ||
        providerRevision < 1 ||
        readbackRevision is! int ||
        readbackRevision < 1 ||
        bytes is! int ||
        bytes < 0 ||
        restarts is! int ||
        restarts < 0 ||
        restarts > 16 ||
        !start.isBefore(end)) {
      _invalid();
    }
    return ServerLiveTvRecording(
      id: _id(value['recordingId']),
      revision: revision,
      providerRevision: providerRevision,
      readbackRevision: readbackRevision,
      programmeId: _id(value['programmeId']),
      channelId: _id(value['channelId']),
      channelName: _text(value['channelName'], 120),
      title: _text(value['title'], 240),
      startsAt: start,
      endsAt: end,
      state: state,
      bytesWritten: bytes,
      restartCount: restarts,
    );
  }

  final String id, programmeId, channelId, channelName, title;
  final int revision,
      providerRevision,
      readbackRevision,
      bytesWritten,
      restartCount;
  final DateTime startsAt, endsAt;
  final ServerLiveTvRecordingState state;
  bool get active =>
      state == ServerLiveTvRecordingState.scheduled ||
      state == ServerLiveTvRecordingState.recording ||
      state == ServerLiveTvRecordingState.interrupted;
}

final class ServerLiveTvSnapshot {
  ServerLiveTvSnapshot._({
    required this.sourceRevision,
    required this.providerRevision,
    required this.providerId,
    required this.providerKind,
    required this.timeZone,
    required this.parallelTuners,
    required this.quotaBytes,
    required this.usedBytes,
    required this.capturedAt,
    required this.programmes,
    required this.recordings,
  });

  factory ServerLiveTvSnapshot.fromJson(Object? raw, ServerSession session) {
    final context = session.context;
    if (context == null) _invalid();
    final value = _object(raw, {
      'schemaVersion',
      'authority',
      'providerId',
      'providerKind',
      'timeZone',
      'parallelTuners',
      'quotaBytes',
      'usedBytes',
      'capturedAt',
      'programmes',
      'recordings',
    });
    final authority = _object(value['authority'], {
      'schemaVersion',
      'coreId',
      'homeId',
      'accountId',
      'accountRevision',
      'sessionFamilyId',
      'sourceRevision',
      'providerRevision',
    });
    final sourceRevision = authority['sourceRevision'];
    final providerRevision = authority['providerRevision'];
    final accountRevision = authority['accountRevision'];
    final kind = value['providerKind'];
    final tuners = value['parallelTuners'];
    final quota = value['quotaBytes'];
    final used = value['usedBytes'];
    if (value['schemaVersion'] != 1 ||
        authority['schemaVersion'] != 1 ||
        authority['coreId'] != context.coreId ||
        authority['homeId'] != context.homeId ||
        authority['accountId'] != session.user.id ||
        authority['sessionFamilyId'] != session.sessionFamilyId ||
        sourceRevision is! int ||
        sourceRevision < 1 ||
        providerRevision is! int ||
        providerRevision < 1 ||
        accountRevision is! int ||
        accountRevision < 1 ||
        (kind != 'tuner' && kind != 'iptv') ||
        tuners is! int ||
        tuners < 1 ||
        tuners > 8 ||
        quota is! int ||
        quota < 1073741824 ||
        (used != null && (used is! int || used < 0 || used > 10995116277760)) ||
        value['programmes'] is! List ||
        value['recordings'] is! List) {
      _invalid();
    }
    final programmes = (value['programmes'] as List)
        .map(ServerLiveTvProgramme.fromJson)
        .toList(growable: false);
    final recordings = (value['recordings'] as List)
        .map(ServerLiveTvRecording.fromJson)
        .toList(growable: false);
    if (programmes.length > 2048 ||
        recordings.length > 256 ||
        programmes.map((item) => item.id).toSet().length != programmes.length ||
        recordings.map((item) => item.id).toSet().length != recordings.length) {
      _invalid();
    }
    final zone = LiveTvTimeZone(_text(value['timeZone'], 64));
    return ServerLiveTvSnapshot._(
      sourceRevision: sourceRevision,
      providerRevision: providerRevision,
      providerId: _text(value['providerId'], 128),
      providerKind: kind as String,
      timeZone: zone,
      parallelTuners: tuners,
      quotaBytes: quota,
      usedBytes: used as int?,
      capturedAt: _instant(value['capturedAt']),
      programmes: programmes,
      recordings: recordings,
    );
  }

  final int sourceRevision, providerRevision, parallelTuners, quotaBytes;
  final int? usedBytes;
  final String providerId, providerKind;
  final LiveTvTimeZone timeZone;
  final DateTime capturedAt;
  final List<ServerLiveTvProgramme> programmes;
  final List<ServerLiveTvRecording> recordings;

  ServerLiveTvRecording? recordingFor(String programmeId) =>
      recordings.cast<ServerLiveTvRecording?>().firstWhere(
        (item) => item?.programmeId == programmeId && item!.active,
        orElse: () => null,
      );
}

final class LiveTvTimeZone {
  LiveTvTimeZone(this.name) {
    if (!_initialized) {
      database.initializeTimeZones();
      _initialized = true;
    }
    try {
      _location = name == 'UTC' ? tz.UTC : tz.getLocation(name);
    } catch (_) {
      _invalid();
    }
  }
  static bool _initialized = false;
  final String name;
  late final tz.Location _location;
  DateTime local(DateTime value) => tz.TZDateTime.from(value, _location);
}

Map<String, dynamic> _object(Object? raw, Set<String> keys) {
  final value = serverObject(raw);
  if (value.length != keys.length || !value.keys.every(keys.contains)) {
    _invalid();
  }
  return value;
}

Never _invalid() => throw const LarenorServerException('invalid_response');

String _id(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

String _text(Object? value, int max) {
  if (value is! String ||
      value.isEmpty ||
      value.length > max ||
      value != value.trim() ||
      value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    _invalid();
  }
  return value;
}

DateTime _instant(Object? value) {
  if (value is! int || value < 1 || value > 253402300799) _invalid();
  return DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true);
}
