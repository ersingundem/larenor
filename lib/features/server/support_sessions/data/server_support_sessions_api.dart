import 'dart:math';

import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_support_session_models.dart';

final class ServerSupportSessionsApi {
  const ServerSupportSessionsApi(this.api, this.token, this.context);
  final LarenorServerApi api;
  final String token;
  final ServerContext context;

  String get _root => '/support-sessions/${context.coreId}/${context.homeId}';

  Future<List<ServerSupportSession>> list() async =>
      ServerSupportSessionList.fromJson(
        await api.request('GET', _root, token: token),
      ).sessions;

  Future<ServerSupportIssuedSession> create({
    required String supporterId,
    required String supporterName,
    required List<String> permissions,
  }) async => ServerSupportIssuedSession.fromJson(
    await api.request(
      'POST',
      _root,
      token: token,
      body: {
        'schemaVersion': 1,
        'requestKey': _requestKey(),
        'supporterId': supporterId,
        'supporterName': supporterName,
        'permissions': [...permissions]..sort(),
        'expiresAt':
            DateTime.now()
                .toUtc()
                .add(const Duration(minutes: 15))
                .millisecondsSinceEpoch /
            1000.0,
      },
    ),
  );

  Future<ServerSupportDetail> detail(ServerSupportSession session) async =>
      ServerSupportDetail.fromJson(
        await api.request('GET', '$_root/${session.id}', token: token),
      );

  Future<ServerSupportSession> revoke(ServerSupportSession session) async {
    final json = await api.request(
      'POST',
      '$_root/${session.id}/revoke',
      token: token,
      body: {'schemaVersion': 1, 'expectedRevision': session.revision},
    );
    if (json?.length != 1 || !json!.containsKey('session')) {
      throw const LarenorServerException('invalid_response');
    }
    final revoked = ServerSupportSession.fromJson(json['session']);
    if (revoked.id != session.id || revoked.state != 'revoked') {
      throw const LarenorServerException('invalid_response');
    }
    return revoked;
  }

  static String _requestKey() {
    final random = Random.secure();
    final value = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return 'support-session:$value';
  }
}
