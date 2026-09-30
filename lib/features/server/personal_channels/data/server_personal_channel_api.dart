import 'dart:math';

import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_personal_channel_models.dart';

final class ServerPersonalChannelApi {
  ServerPersonalChannelApi(
    this.api,
    this.session, {
    String Function()? requestId,
  }) : _requestId = requestId ?? _randomId;

  final LarenorServerApi api;
  final ServerSession session;
  final String Function() _requestId;

  Future<List<ServerPersonalChannel>> list({bool Function()? current}) async {
    _requireCurrent(current);
    final response = _object(
      await api.request(
        'GET',
        '/media/personal-channels',
        token: session.accessToken,
      ),
      {'schemaVersion', 'channels'},
    );
    _requireCurrent(current);
    final raw = response['channels'];
    if (response['schemaVersion'] != 1 || raw is! List || raw.length > 16) {
      throw const LarenorServerException('invalid_response');
    }
    final channels = raw
        .map((value) => ServerPersonalChannel.fromJson(value, session))
        .toList(growable: false);
    if (channels.map((value) => value.id).toSet().length != channels.length) {
      throw const LarenorServerException('invalid_response');
    }
    return List.unmodifiable(channels);
  }

  Future<ServerPersonalChannel> create({
    required String name,
    required DateTime startsAt,
    required bool loop,
    required List<ServerPersonalChannelSource> sources,
    bool Function()? current,
  }) async {
    if (name.isEmpty ||
        name.length > 80 ||
        name != name.trim() ||
        sources.isEmpty ||
        sources.length > 64 ||
        startsAt.toUtc().millisecondsSinceEpoch ~/ 1000 < 1 ||
        sources.fold<int>(
              0,
              (total, source) => total + source.duration.inSeconds,
            ) >
            604800) {
      throw const LarenorServerException('invalid_request');
    }
    return _channel(
      'POST',
      '/media/personal-channels',
      body: {
        'schemaVersion': 1,
        'requestId': _id(),
        'name': name,
        'startsAt': startsAt.toUtc().millisecondsSinceEpoch ~/ 1000,
        'loop': loop,
        'sources': sources
            .map((value) => value.toJson())
            .toList(growable: false),
      },
      current: current,
    );
  }

  Future<ServerPersonalChannel> read(
    String channelId, {
    DateTime? from,
    DateTime? until,
    bool Function()? current,
  }) {
    if ((from == null) != (until == null) ||
        from != null &&
            (!from.isBefore(until!) ||
                until.difference(from).inSeconds > 7 * 24 * 60 * 60)) {
      throw const LarenorServerException('invalid_request');
    }
    final path = from == null
        ? '/media/personal-channels/${_identity(channelId)}'
        : Uri(
            path: '/media/personal-channels/${_identity(channelId)}',
            queryParameters: {
              'from': '${from.toUtc().millisecondsSinceEpoch ~/ 1000}',
              'until': '${until!.toUtc().millisecondsSinceEpoch ~/ 1000}',
            },
          ).toString();
    return _channel('GET', path, current: current);
  }

  Future<ServerPersonalChannel> reschedule({
    required ServerPersonalChannel channel,
    required ServerPersonalProgramme programme,
    required ServerPersonalChannelSource replacement,
    bool Function()? current,
  }) {
    if (programme.state != ServerPersonalProgrammeState.gap ||
        !channel.programmes.any(
          (candidate) => identical(candidate, programme),
        )) {
      throw const LarenorServerException('invalid_request');
    }
    return _channel(
      'POST',
      '/media/personal-channels/${channel.id}/programmes/${programme.id}/reschedule',
      body: {
        'schemaVersion': 1,
        'requestId': _id(),
        'expectedRevision': channel.revision,
        'expectedProgrammeRevision': programme.revision,
        'source': replacement.toJson(),
      },
      current: current,
    );
  }

  Future<ServerPersonalChannel> cancel(
    ServerPersonalChannel channel, {
    bool Function()? current,
  }) => _channel(
    'POST',
    '/media/personal-channels/${channel.id}/cancel',
    body: {
      'schemaVersion': 1,
      'requestId': _id(),
      'expectedRevision': channel.revision,
    },
    current: current,
  );

  Future<ServerPersonalPlaybackSource> resolve({
    required ServerPersonalChannel channel,
    required ServerPersonalProgramme programme,
    required ServerPersonalPlaybackMode mode,
    bool Function()? current,
  }) async {
    if (programme.state != ServerPersonalProgrammeState.scheduled ||
        !channel.programmes.any(
          (candidate) => identical(candidate, programme),
        )) {
      throw const LarenorServerException('invalid_request');
    }
    _requireCurrent(current);
    final response = _object(
      await api.request(
        'POST',
        '/media/personal-channels/${channel.id}/playback',
        token: session.accessToken,
        body: {
          'schemaVersion': 1,
          'expectedChannelRevision': channel.revision,
          'expectedProgrammeRevision': programme.revision,
          'programmeId': programme.id,
          'occurrenceStartsAt':
              programme.startsAt.toUtc().millisecondsSinceEpoch ~/ 1000,
          'mode': mode.name,
        },
      ),
      {'playback'},
    );
    _requireCurrent(current);
    return ServerPersonalPlaybackSource.fromJson(
      response['playback'],
      channel: channel,
      programme: programme,
    );
  }

  Future<ServerPersonalChannelExecution> startContinuous({
    required ServerPersonalPlaybackSource source,
    required String targetId,
    bool Function()? current,
  }) async {
    _requireCurrent(current);
    final response = _object(
      await api.request(
        'POST',
        '/media/personal-channels/${source.channelId}/continuous',
        token: session.accessToken,
        body: {
          'schemaVersion': 1,
          'requestId': _id(),
          'expectedChannelRevision': source.channelRevision,
          'expectedProgrammeRevision': source.programmeRevision,
          'programmeId': source.programmeId,
          'occurrenceStartsAt':
              source.occurrenceStartsAt.millisecondsSinceEpoch ~/ 1000,
          'targetId': _target(targetId),
        },
      ),
      {'execution'},
    );
    _requireCurrent(current);
    return ServerPersonalChannelExecution.fromJson(
      response['execution'],
      expectedChannelId: source.channelId,
      expectedSource: source,
      expectedTargetId: targetId,
    );
  }

  Future<ServerPersonalChannelExecution> readContinuous(
    String channelId, {
    bool Function()? current,
  }) async {
    final id = _identity(channelId);
    _requireCurrent(current);
    final response = _object(
      await api.request(
        'GET',
        '/media/personal-channels/$id/continuous',
        token: session.accessToken,
      ),
      {'execution'},
    );
    _requireCurrent(current);
    return ServerPersonalChannelExecution.fromJson(
      response['execution'],
      expectedChannelId: id,
    );
  }

  Future<ServerPersonalChannelExecution> stopContinuous(
    ServerPersonalChannelExecution execution, {
    bool Function()? current,
  }) async {
    _requireCurrent(current);
    final response = _object(
      await api.request(
        'POST',
        '/media/personal-channels/${execution.channelId}/continuous/cancel',
        token: session.accessToken,
        body: {
          'schemaVersion': 1,
          'requestId': _id(),
          'expectedExecutionRevision': execution.revision,
        },
      ),
      {'execution'},
    );
    _requireCurrent(current);
    return ServerPersonalChannelExecution.fromJson(
      response['execution'],
      expectedChannelId: execution.channelId,
      expectedTargetId: execution.targetId,
    );
  }

  Future<ServerPersonalChannel> _channel(
    String method,
    String path, {
    Map<String, Object?>? body,
    bool Function()? current,
  }) async {
    _requireCurrent(current);
    final response = _object(
      await api.request(method, path, token: session.accessToken, body: body),
      {'channel'},
    );
    _requireCurrent(current);
    return ServerPersonalChannel.fromJson(response['channel'], session);
  }

  String _id() {
    final value = _requestId();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
      throw const LarenorServerException('invalid_request');
    }
    return value;
  }

  static String _identity(String value) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
      throw const LarenorServerException('invalid_request');
    }
    return value;
  }

  static String _target(String value) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}$').hasMatch(value)) {
      throw const LarenorServerException('invalid_request');
    }
    return value;
  }

  static Map<String, dynamic> _object(Object? raw, Set<String> keys) {
    final value = serverObject(raw);
    if (value.length != keys.length || !value.keys.every(keys.contains)) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  }

  static void _requireCurrent(bool Function()? current) {
    if (current != null && !current()) {
      throw const LarenorServerException('retired');
    }
  }

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}
