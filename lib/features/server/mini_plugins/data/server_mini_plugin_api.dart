import 'dart:math';

import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_mini_plugin_models.dart';

final class ServerMiniPluginApi {
  const ServerMiniPluginApi(this.api, this.token, this.context);
  final LarenorServerApi api;
  final String token;
  final ServerContext context;
  String get _root => '/mini-plugins/${context.coreId}/${context.homeId}';

  Future<ServerMiniPluginCatalog> catalog() async =>
      ServerMiniPluginCatalog.fromJson(
        await api.request('GET', '$_root/catalog', token: token),
      );

  Future<List<ServerMiniPluginInstance>> list() async {
    final json = serverObject(await api.request('GET', _root, token: token));
    final instances = json['instances'];
    if (json.length != 4 ||
        json['schemaVersion'] != 1 ||
        json['maximumInstances'] != 64 ||
        json['maximumRunning'] != 8 ||
        instances is! List ||
        instances.length > 64) {
      throw const LarenorServerException('invalid_response');
    }
    return List.unmodifiable(instances.map(ServerMiniPluginInstance.fromJson));
  }

  Future<ServerMiniPluginInstance> create(String displayName) async =>
      _instance(
        await api.request(
          'POST',
          _root,
          token: token,
          body: {
            'schemaVersion': 1,
            'requestKey': _requestKey('mini-plugin'),
            'templateId': 'home-resource-count',
            'displayName': displayName,
          },
        ),
      );

  Future<ServerMiniPluginInstance> stop(
    ServerMiniPluginInstance instance,
  ) async {
    final stopped = _instance(
      await api.request(
        'POST',
        '$_root/${instance.id}/stop',
        token: token,
        body: {
          'schemaVersion': 1,
          'requestKey': _requestKey('mini-plugin-stop'),
          'expectedRevision': instance.revision,
        },
      ),
    );
    if (stopped.id != instance.id || stopped.running) {
      throw const LarenorServerException('invalid_response');
    }
    return stopped;
  }

  Future<ServerMiniPluginSnapshot> render(
    ServerMiniPluginInstance instance,
  ) async {
    final json = await api.request(
      'POST',
      '$_root/${instance.id}/render',
      token: token,
      body: {'schemaVersion': 1, 'expectedRevision': instance.revision},
    );
    if (json?.length != 1 || !json!.containsKey('result')) {
      throw const LarenorServerException('invalid_response');
    }
    final result = ServerMiniPluginSnapshot.fromJson(json['result']);
    if (result.pluginId != instance.id ||
        result.pluginRevision != instance.revision) {
      throw const LarenorServerException('invalid_response');
    }
    return result;
  }

  static ServerMiniPluginInstance _instance(Map<String, dynamic>? json) {
    if (json?.length != 1 || !json!.containsKey('instance')) {
      throw const LarenorServerException('invalid_response');
    }
    return ServerMiniPluginInstance.fromJson(json['instance']);
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
