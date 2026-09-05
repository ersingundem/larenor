import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_plugin_models.dart';

/// Metadata-only endpoints. No execution, image pull or installation API exists
/// in this Client flow.
class ServerPluginsApi {
  const ServerPluginsApi(this.api, this.token);
  final LarenorServerApi api;
  final String token;

  Future<ServerPluginCatalog> catalog() async => ServerPluginCatalog.fromJson(
    await api.request('GET', '/admin/plugins/catalog', token: token),
  );

  Future<ServerPluginPreview> preview(
    PluginCatalogEntry entry, {
    required String platform,
    required Map<String, Object?> settings,
  }) async {
    final manifest = entry.manifest;
    if (!manifest.images.any((image) => image.platform == platform) ||
        !manifest.acceptsSettings(settings)) {
      throw const LarenorServerException('invalid_request');
    }
    final requested = Map<String, Object?>.unmodifiable(settings);
    final json = await api.request(
      'POST',
      '/admin/plugins/previews',
      token: token,
      body: {
        'serviceId': manifest.serviceId,
        'distributionId': manifest.distributionId,
        'manifestDigest': entry.manifestDigest,
        'platform': platform,
        'settings': requested,
      },
    );
    if (json?.length != 1 || !json!.containsKey('preview')) {
      throw const LarenorServerException('invalid_response');
    }
    final preview = ServerPluginPreview.fromJson(json['preview']);
    if (!preview.plan.matches(entry, platform, requested)) {
      throw const LarenorServerException('invalid_response');
    }
    return preview;
  }

  @override
  String toString() => 'ServerPluginsApi';
}
