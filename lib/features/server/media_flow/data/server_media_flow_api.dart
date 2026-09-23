import 'dart:math';

import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_media_flow_models.dart';

final class ServerMediaFlowApi {
  ServerMediaFlowApi(this.api, this.token, {String Function()? requestId})
    : _requestId = requestId ?? _randomId;

  final LarenorServerApi api;
  final String token;
  final String Function() _requestId;

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<ServerMediaFlowAuthority> readAuthority(
    String mediaKey, {
    bool Function()? current,
  }) async {
    if (!validServerMediaKey(mediaKey)) {
      throw const LarenorServerException('invalid_request');
    }
    final requestId = _requestId();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId)) {
      throw const LarenorServerException('invalid_request');
    }
    _requireCurrent(current);
    try {
      final authority = ServerMediaFlowAuthority.fromJson(
        await api.request(
          'POST',
          '/admin/media/flows/authority',
          token: token,
          body: {'requestId': requestId, 'mediaKey': mediaKey},
        ),
      );
      _requireCurrent(current);
      if (authority.requestId != requestId || authority.mediaKey != mediaKey) {
        throw const FormatException('invalid_response');
      }
      return authority;
    } on FormatException {
      throw const LarenorServerException('invalid_response');
    }
  }

  Future<ServerMediaFlowStatus> readAuthorized(
    ServerMediaFlowAuthority authority, {
    bool Function()? current,
  }) async {
    _requireCurrent(current);
    try {
      final response = _object(
        await api.request(
          'POST',
          '/admin/media/flows/read',
          token: token,
          body: {
            'requestId': authority.requestId,
            'mediaKey': authority.mediaKey,
            'expectedFlowRevision': authority.flowRevision,
            'expectedSources': [
              for (final source in authority.sources) source.toJson(),
            ],
          },
        ),
        {'requestId', 'flow'},
      );
      _requireCurrent(current);
      if (response['requestId'] != authority.requestId) {
        throw const FormatException('invalid_response');
      }
      final flow = ServerMediaFlowStatus.fromJson(response['flow']);
      if (flow.mediaKey != authority.mediaKey ||
          flow.flowRevision != authority.flowRevision ||
          !_sameSources(flow.sources, authority.sources)) {
        throw const FormatException('invalid_response');
      }
      return flow;
    } on FormatException {
      throw const LarenorServerException('invalid_response');
    }
  }

  Future<ServerMediaFlowStatus> read(
    String mediaKey, {
    bool Function()? current,
  }) async {
    final authority = await readAuthority(mediaKey, current: current);
    return readAuthorized(authority, current: current);
  }

  static void _requireCurrent(bool Function()? current) {
    if (current == null) return;
    try {
      if (current()) return;
    } catch (_) {
      // A retired owner is indistinguishable from a false owner callback.
    }
    throw const LarenorServerException('retired');
  }

  static bool _sameSources(
    List<ServerMediaFlowSource> left,
    List<ServerMediaFlowSource> right,
  ) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      final a = left[index], b = right[index];
      if (a.provider != b.provider ||
          a.serviceRevision != b.serviceRevision ||
          a.snapshotRevision != b.snapshotRevision ||
          a.observedAt != b.observedAt) {
        return false;
      }
    }
    return true;
  }

  static Map<String, dynamic> _object(Object? value, Set<String> keys) {
    if (value is! Map<String, dynamic> ||
        value.length != keys.length ||
        !value.keys.every(keys.contains)) {
      throw const FormatException('invalid_response');
    }
    return value;
  }
}
