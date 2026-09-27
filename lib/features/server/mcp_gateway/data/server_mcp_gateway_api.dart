import 'dart:math';

import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_mcp_gateway_models.dart';

final class ServerMcpGatewayApi {
  const ServerMcpGatewayApi(this.api, this.token, this.context);
  final LarenorServerApi api;
  final String token;
  final ServerContext context;

  String get _root => '/mcp-gateway/${context.coreId}/${context.homeId}';

  Future<List<ServerMcpGrant>> list() async => ServerMcpGrantList.fromJson(
    await api.request('GET', '$_root/grants', token: token),
  ).grants;

  Future<ServerMcpIssuedGrant> create({
    required String clientId,
    required String clientName,
    required List<String> tools,
  }) async => ServerMcpIssuedGrant.fromJson(
    await api.request(
      'POST',
      '$_root/grants',
      token: token,
      body: {
        'schemaVersion': 1,
        'requestKey': _requestKey('mcp-grant'),
        'clientId': clientId,
        'clientName': clientName,
        'tools': [...tools]..sort(),
        'expiresAt':
            DateTime.now()
                .toUtc()
                .add(const Duration(minutes: 30))
                .millisecondsSinceEpoch /
            1000.0,
      },
    ),
  );

  Future<ServerMcpGrant> revoke(ServerMcpGrant grant) async {
    final json = await api.request(
      'POST',
      '$_root/grants/${grant.id}/revoke',
      token: token,
      body: {'schemaVersion': 1, 'expectedRevision': grant.revision},
    );
    if (json?.length != 1 || !json!.containsKey('grant')) {
      throw const LarenorServerException('invalid_response');
    }
    final revoked = ServerMcpGrant.fromJson(json['grant']);
    if (revoked.id != grant.id || revoked.state != 'revoked') {
      throw const LarenorServerException('invalid_response');
    }
    return revoked;
  }

  static String _requestKey(String prefix) {
    final random = Random.secure();
    final value = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return '$prefix:$value';
  }
}
